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
#include "Utils/Transient/Transient.h"
#include "Rendering/Lights/LightBVHSampler.h"

using namespace Falcor;

/** Time-gated path tracing with direct or ellipsoidal connection sampling. */
class TimeGatedPathTracerInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TimeGatedPathTracerInline, "TimeGatedPathTracerInline", "Time-gated path tracer.");

    static ref<TimeGatedPathTracerInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TimeGatedPathTracerInline>(pDevice, props);
    }

    TimeGatedPathTracerInline(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }
    // Scripting functions
    void incrementTimeGateFrame();
    void setTimeGateInfo(float timeMin, float timeMax, uint timeBin);

private:
    enum class TimeGatedSamplingMethod
    {
        DIRECT = 0,
        ELLIPSOIDAL = 1,
        ELLIPSOIDAL_DIRECT_MIS = 2,
    };

    static const std::unordered_map<std::string, TimeGatedSamplingMethod>& getSamplingMethods();
    void parseProperties(const Properties& props);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;

    /// User settings. The sampling method selects whether to use direct/ellipsoidal MIS.
    struct Options
    {
        uint maxBounces = 3;
        bool computeDirect = true;
        bool useImportanceSampling = true;
        float timeGateWindow = 0.05f;
        TimeGateMode timeGateMode = TimeGateMode::BOX;
        float timeMin = 9.0f;
        float timeMax = 12.0f;
        uint timeBin = 512;
        float specularRoughnessThreshold = 0.25f;
        TimeGatedSamplingMethod samplingMethod = TimeGatedSamplingMethod::DIRECT;
        EmissiveLightSamplerType triSampler = EmissiveLightSamplerType::Uniform;
        bool laserCollocated = false;
        bool useAlphaTest = false;
        bool useSingleChannel = false;
        bool isLightSourceLaser = true;
        uint samplesPerPixel = 128;
    };

    struct FrameState
    {
        uint frameCount = 0;
        uint gateIndex = 0;
        uint previousGateIndex = 0;
        float gatePosition = 0.f;
        float previousGatePosition = 0.f;
    };

    static void validateOptions(const Options& options);
    void updateGatePosition();
    void prepareLightSampler(RenderContext* pRenderContext);
    void prepareProgram(RenderContext* pRenderContext, const RenderData& renderData);

    Options mOptions;
    FrameState mFrameState;
    bool mOptionsChanged = false;

    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    std::unique_ptr<EmissiveLightSampler> mpEmissiveSampler;
    LightBVHSampler::Options mLightBVHOptions;
    ref<ComputePass> mpComputePass;
};
