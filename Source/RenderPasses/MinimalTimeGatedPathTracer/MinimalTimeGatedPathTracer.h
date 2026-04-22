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
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EmissiveUniformSampler.h"

using namespace Falcor;


enum class TimeGatedSamplingMethod
{
    DIRECT = 0,
    ELLIPSOIDAL = 1,
    TRIANGLE_APPROX = 2,
};

static const std::unordered_map<std::string, TimeGatedSamplingMethod> SamplingMethodTable = {
    {"direct", TimeGatedSamplingMethod::DIRECT},
    {"ellipsoidal", TimeGatedSamplingMethod::ELLIPSOIDAL},
    {"tri_approx", TimeGatedSamplingMethod::TRIANGLE_APPROX}
};


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
class MinimalTimeGatedPathTracer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(MinimalTimeGatedPathTracer, "MinimalTimeGatedPathTracer", "Minimal path tracer.");

    static ref<MinimalTimeGatedPathTracer> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<MinimalTimeGatedPathTracer>(pDevice, props);
    }

    MinimalTimeGatedPathTracer(ref<Device> pDevice, const Properties& props);

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
    void prepareVars();
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;
    


    // Internal state

    /// Current scene.
    ref<Scene> mpScene;
    /// GPU sample generator.
    ref<SampleGenerator> mpSampleGenerator;

    // Configuration

    /// Max number of indirect bounces (0 = none).
    uint mMaxBounces = 3;
    /// Compute direct illumination (otherwise indirect only).
    bool mComputeDirect = true;
    /// Use importance sampling for materials.
    bool mUseImportanceSampling = true;

    // Runtime data

    // Time Gate Data
    float mTimeGateWindow = 0.05f;
    TimeGateMode mTimeGateMode = TimeGateMode::BOX;
    float mTimeMin = 9.0f;
    float mTimeMax = 12.0f;
    uint mTimeBin = 512;
    float mSpecularRoughnessThreshold = 0.25f;

    float mTcurr;
    float mTprev;

    TimeGatedSamplingMethod mSamplingMethod = TimeGatedSamplingMethod::DIRECT;
    EmissiveLightSamplerType mTriSampler = EmissiveLightSamplerType::Uniform;
    // bool mDoSampleLaser = true;
    bool mLaserCollocated = false;
    bool mUseAlphaTest = false;
    bool mUseEllipsoidalMIS = true;
    bool mUseSingleChannel = false;
    bool mIsLightSourceLaser = true;

    /// Frame count since scene was loaded.
    uint mFrameCount = 0;
    uint mTimeGateFrameCount = 0;
    uint mPrevTimeGateFrameCount = 0;
    bool mOptionsChanged = false;
    uint mSamplesPerPixel = 128;
    
    EmissiveLightSamplerType emissiveSampler = EmissiveLightSamplerType::LightBVH;  ///< Emissive light sampler to use for NEE.
    std::unique_ptr<EmissiveLightSampler> mpEmissiveSampler;    ///< Emissive light sampler or nullptr if not used.
    mutable LightBVHSampler::Options mLightBVHOptions;          ///< Current options for the light BVH sampler.
    
    // Ray tracing program.
    ref<ComputePass> mpComputePass;
};
