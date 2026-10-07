/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "../Shared/Host/Configs/TransientHistogramConfig.h"
#include "../Shared/Host/Configs/PathTracingConfig.h"
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/Configs/PathLengthAwareReSTIRConfig.h"
#include "../Shared/Host/InlinePassUtils.h"

using namespace Falcor;


/** Transient-histogram ReSTIR: one reservoir per histogram bin, filled from path tracing, then spatial and temporal
 * reuse of the paths across pixels, shifted with a path-length-aware shift mapping so that they stay in their bin.
 */
class TransientHistogramReSTIRInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TransientHistogramReSTIRInline, "TransientHistogramReSTIRInline", "Transient histogram ReSTIR.");

    static ref<TransientHistogramReSTIRInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TransientHistogramReSTIRInline>(pDevice, props);
    }

    TransientHistogramReSTIRInline(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }
    // Scripting functions
    void resetHistogram();
    
private:
    void parseProperties(const Properties& props);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;
    const ChannelList& histogramChannels() const;
    void bindTimeGate(const ShaderVar& var) const;
    /// Allocates the pair records shared by the two-pass spatial and temporal reuse and returns the bins per chunk of
    /// each (spatialChunkBins, temporalChunkBins).
    void preparePairs(uint2 frameDim, uint& spatialChunkBins, uint& temporalChunkBins);
    /// Two-pass temporal reuse (useTemporalReusePairs), per chunk of `chunkBins` bins, after initial generation.
    void temporalReuse(RenderContext* pRenderContext, const RenderData& renderData, uint chunkBins);
    void spatialReuse(RenderContext* pRenderContext, const RenderData& renderData, uint chunkBins);
    /// Binds the spatial reuse constants and resources of `pass` (the resampling or the pair pass).
    void bindSpatialReuse(const ref<ComputePass>& pass, const RenderData& renderData);
    /// Spatial reuse runs as two passes per iteration and chunk of bins (pair shifts, then resampling) when
    /// spatialReuseTwoPass is set, unless the shift is `no`: without shift work, the extra pass and its records cost
    /// more than the occupancy gains.
    bool useSpatialReusePairs() const
    {
        return mOptions.restir.spatialReuseTwoPass &&
               mOptions.restir.shiftMapping.shiftmapMethod != ShiftMappingMethod::Identity;
    }
    /// Temporal reuse runs as two passes after initial generation per chunk of bins (the merge shifts of each bin, then
    /// the merges) when temporalReuseTwoPass is set, unless the shift is `no` (as for spatial reuse).
    bool useTemporalReusePairs() const
    {
        return mOptions.restir.useTemporalReuse && mOptions.temporalReuseTwoPass &&
               mOptions.restir.shiftMapping.shiftmapMethod != ShiftMappingMethod::Identity;
    }

    /// User settings, composed of shared configs (Shared/Host/Configs) plus this pass's own.
    struct Options
    {
        TransientHistogramConfig histogram;
        PathTracingConfig pathTracing;
        PathLengthAwareReSTIRConfig restir;
        bool useBinReuse = false; ///< Add adjacent bins of the same pixel as spatial reuse candidates.
        /// Store only non-empty reservoirs, with every reservoir's W and M in a compact buffer (RESERVOIR_SUMMARIES).
        bool skipEmptyReservoirs = true;
        /// Temporal reuse in two passes after initial generation instead of inside it (TEMPORAL_REUSE_PAIRS).
        bool temporalReuseTwoPass = true;
    };
    Options mOptions;
    /// Throws if `options` are invalid: checked on creation and UI edits.
    static void validateOptions(const Options& options);
    /// Rebuilds what the new options need (after a UI edit or setProperties) and flags the change.
    void onOptionsChanged(const Options& previous);

    ref<Scene> mpScene;
    LaserInput mLaserInput; ///< The laser of this frame, from the LaserLight pass.
    ref<SampleGenerator> mpSampleGenerator;

    // Runtime state of the composed configs.
    LaserState mLaser;
    LaserState mPreviousLaser;
    PathLengthAwareReSTIRResources mReSTIR;

    uint mFrameCount = 0; ///< Frames since the scene was loaded.
    uint mRandomSeed = 0;
    bool mOptionsChanged = false;
    bool mNeedToClearHistogram = false;
    std::string mUIWarning; ///< Why the last UI edit was rejected.

    ref<ComputePass> mpComputePass;      ///< Initial candidates (and temporal reuse), written to the histogram.
    /// With TEMPORAL_REUSE_PAIRS, the temporal reuse after initial generation: the merge shifts of one pixel and bin per
    /// thread (TemporalReusePairs.cs.slang), then the merges (TemporalReuse.cs.slang).
    ref<ComputePass> mpTemporalPairsPass;
    ref<ComputePass> mpTemporalResamplePass;
    ref<Buffer> mpTemporalRandomState; ///< Each pixel's reservoir random state after initial generation.
    ref<Buffer> mpTemporalHistoryPixel; ///< Each pixel's history pixel, found by initial generation (two-pass temporal).
    ref<Buffer> mpTouchedBins; ///< Initial generation's bits of the bins from 64 on that received a candidate.
    ref<ComputePass> mpSpatialReusePass;
    /// With SPATIAL_REUSE_PAIRS, the first pass of each spatial reuse iteration: one candidate's shifts per thread.
    ref<ComputePass> mpSpatialReusePairsPass;
};
