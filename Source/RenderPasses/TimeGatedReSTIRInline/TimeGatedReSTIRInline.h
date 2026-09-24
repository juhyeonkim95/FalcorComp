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
#include "../Shared/Configs/TimeGateConfig.h"
#include "../Shared/Configs/EllipsoidalSamplingConfig.h"
#include "../Shared/Configs/PathTracingConfig.h"
#include "../Shared/Configs/PathLengthAwareReSTIRConfig.h"
#include "../Shared/Utils/InlinePassUtils.h"

using namespace Falcor;


/**
 * Minimal path tracer.
 *
 * This pass implements a minimal brute-force path tracer. It does purposely
 * not use any importance sampling or other variance reduction techniques.
 * The output is unbiased/consistent ground truth images, against which other
 * renderers can be validated.
 *
 * Note that transmission and nested dielectrics are not yet supported.
 */
class TimeGatedReSTIRInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TimeGatedReSTIRInline, "TimeGatedReSTIRInline", "Minimal path tracer.");

    static ref<TimeGatedReSTIRInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TimeGatedReSTIRInline>(pDevice, props);
    }

    TimeGatedReSTIRInline(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
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
    DefineList getShaderDefines(const RenderData& renderData) const;
    DefineList getReservoirDefines() const;
    void spatialReuse(RenderContext* pRenderContext, const RenderData& renderData);

    /// User settings, composed of shared configs (Shared/Configs) plus this pass's own.
    struct Options
    {
        TimeGateConfig timeGate;
        EllipsoidalSamplingConfig ellipsoidalSampling;
        PathTracingConfig pathTracing;
        PathLengthAwareReSTIRConfig restir;
        bool isSceneDynamic = false;          ///< Keep the history when the light moves, re-evaluating reused paths.
        bool debugNewtonIterations = false;   ///< Adds the newtonStatistics and mappingDistance outputs.
        float timeGateWindowRough = 0.0f;     ///< Direct sampling: wide gate traced by some paths and shrunk into the gate.
        float roughTimeGateSampleRatio = 0.5f; ///< Fraction of paths traced with the wide gate.
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
};
