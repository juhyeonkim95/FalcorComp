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
#include "RenderGraph/RenderPassHelpers.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Utils/Transient/Transient.h"
#include "../Shared/Configs/TransientHistogramConfig.h"
#include "../Shared/Configs/PathTracingConfig.h"

using namespace Falcor;

/** Inline transient histogram tracer. Histogram values accumulate until resetHistogram(), or until the
 * camera moves or an upstream pass changes its options when autoReset is enabled. The number of
 * accumulated frames is published in the render data dictionary (kHistogramFrameCount).
 * Single-channel output stores the red channel in an H x W x B volume; RGB uses float4 bins.
 * Triangle approximation integrates a single intermediate triangle, not a full path walk.
 */
class TransientHistogramPathTracerInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TransientHistogramPathTracerInline, "TransientHistogramPathTracerInline", "Inline path tracer for transient histograms.");
    static ref<TransientHistogramPathTracerInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TransientHistogramPathTracerInline>(pDevice, props);
    }
    TransientHistogramPathTracerInline(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    void resetHistogram();

private:
    enum class SamplingMethod { Direct = 0, TriangleApprox = 2 };
    /// User settings, composed of shared configs (Shared/Configs) plus this pass's own.
    struct Options
    {
        TransientHistogramConfig histogram;
        PathTracingConfig pathTracing;
        SamplingMethod samplingMethod = SamplingMethod::Direct;
        bool autoReset = false; ///< Clear the histogram when the camera moves or an upstream pass changes options.
        RenderPassHelpers::IOSize outputSize = RenderPassHelpers::IOSize::Default;
        uint2 fixedOutputSize = {512, 512}; ///< Output size when outputSize is Fixed.
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);
    void prepareProgram(RenderContext* pRenderContext, const RenderData& renderData);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    bool needsAutoReset(const RenderData& renderData) const;
    DefineList getShaderDefines(const RenderData& renderData) const;

    Options mOptions;
    uint mFrameCount = 0;
    uint mHistogramFrameCount = 0; ///< Frames accumulated in the histogram since it was cleared.
    bool mOptionsChanged = false;
    std::string mUIWarning; ///< Why the last UI edit was rejected.
    bool mNeedToClearHistogram = true;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
};
