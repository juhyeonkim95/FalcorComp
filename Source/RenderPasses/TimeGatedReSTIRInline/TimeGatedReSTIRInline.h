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
#include <algorithm>
#include "../Shared/Host/Configs/TimeGateConfig.h"
#include "../Shared/Host/Configs/EllipsoidalSamplingConfig.h"
#include "../Shared/Host/Configs/PathTracingConfig.h"
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/Configs/PathLengthAwareReSTIRConfig.h"
#include "../Shared/Host/InlinePassUtils.h"

using namespace Falcor;


/** Time-gated ReSTIR: initial candidates from path tracing, then spatial and temporal reuse of the paths across pixels,
 * shifted with a path-length-aware shift mapping so that they stay inside the time gate.
 */
class TimeGatedReSTIRInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TimeGatedReSTIRInline, "TimeGatedReSTIRInline", "Time-gated ReSTIR.");

    static ref<TimeGatedReSTIRInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TimeGatedReSTIRInline>(pDevice, props);
    }

    TimeGatedReSTIRInline(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    /// Changes options of the live pass (pass.set_properties() from Python), like an edit in the UI.
    virtual void setProperties(const Properties& props) override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }
    // Scripting functions
    void incrementTimeGateFrame();
    void setTimeGateInfo(float timeMin, float timemax, uint timeBin);
    
private:
    void parseProperties(const Properties& props);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    /// Binds the spatial reuse constants and resources of `pass` (the resampling or the pair pass).
    void bindSpatialReuse(const ref<ComputePass>& pass, const RenderData& renderData);
    /// Spatial reuse runs as two passes per iteration (pair shifts, then resampling) unless the Newton debug outputs are
    /// on, which only the single-pass kernel writes, or the shift is `no`: without shift work, the extra pass and
    /// its records cost more than the occupancy gains.
    bool useSpatialReusePairs() const
    {
        return !mOptions.debugNewtonIterations &&
               mOptions.restir.shiftMapping.shiftmapMethod != ShiftMappingMethod::Identity;
    }
    DefineList getShaderDefines(const RenderData& renderData) const;
    /// Shrink mapping's wide-gate path fraction, clamped to [0, 1]; the host and the shader derive the wide path
    /// count from it the same way.
    float shrinkSampleRatio() const { return std::clamp(mOptions.roughTimeGateSampleRatio, 0.f, 1.f); }
    void spatialReuse(RenderContext* pRenderContext, const RenderData& renderData);
    void addDirect(RenderContext* pRenderContext, const RenderData& renderData);

    /// User settings, composed of shared configs (Shared/Host/Configs) plus this pass's own.
    struct Options
    {
        TimeGateConfig timeGate;
        EllipsoidalSamplingConfig ellipsoidalSampling;
        PathTracingConfig pathTracing;
        PathLengthAwareReSTIRConfig restir;
        bool isSceneDynamic = false;          ///< Keep the history when the light moves, re-evaluating reused paths.
        bool debugNewtonIterations = false;   ///< Adds the newtonStatistics and mappingDistance outputs.
        /// Direct sampling with a box or tent gate: trace paths with a wider gate and shrink them into the gate.
        bool useShrinkMapping = false;
        float timeGateWindowRough = 0.0f;      ///< Width of the wide gate; 0 means 10 x timeGateWindow.
        float roughTimeGateSampleRatio = 1.0f; ///< Fraction of the paths traced with the wide gate.

        /// Width of the wide gate that shrink mapping traces.
        float wideGateWindow() const { return timeGateWindowRough > 0.f ? timeGateWindowRough : 10.f * timeGate.timeGateWindow; }
    };
    Options mOptions;

    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;

    // Runtime state of the composed configs.
    TimeGateState mGate;
    LaserState mLaser;
    LaserState mPreviousLaser;
    EllipsoidalTriangleSampler mTriangleSampler;
    PathLengthAwareReSTIRResources mReSTIR;

    uint mFrameCount = 0; ///< Frames since the scene was loaded.
    uint mRandomSeed = 0;
    bool mOptionsChanged = false;
    bool mGateMoved = false; ///< The gate shifted: restart accumulation but keep the ReSTIR history.
    std::string mUIWarning;  ///< Why the last UI edit was rejected.

    ref<ComputePass> mpComputePass;      ///< Initial candidates (and temporal reuse).
    ref<ComputePass> mpSpatialReusePass;
    /// With SPATIAL_REUSE_PAIRS, the first pass of each spatial reuse iteration: one candidate's shifts per thread.
    ref<ComputePass> mpSpatialReusePairsPass;
    ref<ComputePass> mpAddDirectPass;    ///< Adds the primary-hit direct lighting to the output (computeDirect).
    ref<Texture> mpDirectColor;          ///< Primary-hit direct lighting, kept out of the reservoirs (computeDirect).
};
