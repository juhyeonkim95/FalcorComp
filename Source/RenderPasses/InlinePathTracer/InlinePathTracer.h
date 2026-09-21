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

using namespace Falcor;

/** Simple steady-state path tracer using inline ray queries.
 * Analytic lights are sampled explicitly; mesh lights and environment lighting
 * are sampled by BSDF continuation. No reservoir reuse or light-sampling MIS.
 */
class InlinePathTracer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(InlinePathTracer, "InlinePathTracer", "Simple inline path tracer.");

    static ref<InlinePathTracer> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<InlinePathTracer>(pDevice, props);
    }

    InlinePathTracer(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

private:
    struct Options
    {
        uint maxBounces = 3; ///< Maximum indirect bounces; zero still evaluates direct lighting.
        uint samplesPerPixel = 1;
        bool computeDirect = true;
        bool useImportanceSampling = true;
        bool useAlphaTest = true;
    };

    void parseProperties(const Properties& props);
    DefineList getShaderDefines(const RenderData& renderData) const;
    void prepareProgram(RenderContext* pRenderContext, const RenderData& renderData);
    void bindShaderData(RenderContext* pRenderContext, const RenderData& renderData);

    Options mOptions;
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
};
