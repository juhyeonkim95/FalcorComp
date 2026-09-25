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
#include "../Shared/Host/Configs/TimeGateConfig.h"
#include "../Shared/Host/Configs/EllipsoidalSamplingConfig.h"
#include "../Shared/Host/Configs/PathTracingConfig.h"
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/InlinePassUtils.h"

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
    void parseProperties(const Properties& props);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;

    /// User settings, composed of shared configs (Shared/Host/Configs).
    struct Options
    {
        TimeGateConfig timeGate;
        EllipsoidalSamplingConfig ellipsoidalSampling;
        PathTracingConfig pathTracing;
    };

    static void validateOptions(const Options& options);

    Options mOptions;
    uint mFrameCount = 0;
    TimeGateState mGate;
    bool mOptionsChanged = false;

    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    EllipsoidalTriangleSampler mTriangleSampler;
    ref<ComputePass> mpComputePass;
};
