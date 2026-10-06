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
#include "../Shared/Host/Configs/PathTracingConfig.h"
#include "../Shared/Host/Configs/ProjectorConfig.h"
#include "../Shared/Host/InlinePassUtils.h"
#include <vector>

using namespace Falcor;

/// How the vertex lit by the projector is reached from the camera path (SAMPLING_METHOD in the shader).
enum class StructuredLightSamplingMethod : uint32_t
{
    BSDF = 0,       ///< BSDF sampling.
    Antithetic = 1, ///< BSDF sampling, each sample paired with its antithetic partner in projector space.
    Projector = 2,  ///< Sampled from the projector, stratified along the pattern axis, and connected.
};

/** Structured-light path tracer: a projector shows a signed pattern and camera paths are connected to it.
 * With antithetic sampling, each BSDF-sampled vertex is paired with the point lit through the pattern's
 * antithetic uv, where the pattern has the opposite sign.
 */
class StructuredLightPathTracerInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(StructuredLightPathTracerInline, "StructuredLightPathTracerInline", "Structured-light path tracer.");

    static ref<StructuredLightPathTracerInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<StructuredLightPathTracerInline>(pDevice, props);
    }

    StructuredLightPathTracerInline(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }
    // Scripting functions
    void setPatternData(std::vector<uint32_t> values, std::vector<uint32_t> antitheticIndex,
        std::vector<uint32_t> intervalIds, std::vector<uint32_t> intervals);

private:
    void parseProperties(const Properties& props);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;

    /// User settings, composed of shared configs (Shared/Host/Configs).
    struct Options
    {
        ProjectorConfig projector;
        PathTracingConfig pathTracing;
        StructuredLightSamplingMethod samplingMethod = StructuredLightSamplingMethod::Antithetic;
        uint projectorSampleCount = 1; ///< Projector samples per vertex with StructuredLightSamplingMethod::Projector.
    };

    static void validateOptions(const Options& options);

    Options mOptions;
    ProjectorPatternData mPatternData;
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
    std::string mUIWarning; ///< Why the last UI edit was rejected.

    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
};
