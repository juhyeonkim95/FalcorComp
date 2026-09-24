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
#include "../Shared/Configs/TransientHistogramConfig.h"
#include "../Shared/Configs/PathTracingConfig.h"
#include "../Shared/Configs/ReSTIRConfig.h"

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
class TransientHistogramReSTIRInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TransientHistogramReSTIRInline, "TransientHistogramReSTIRInline", "Minimal path tracer.");

    static ref<TransientHistogramReSTIRInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TransientHistogramReSTIRInline>(pDevice, props);
    }

    TransientHistogramReSTIRInline(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
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
    void prepareVars();
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);
    void spatialReuse(RenderContext* pRenderContext, const RenderData& renderData);
    void finalEvaluate(RenderContext* pRenderContext, const RenderData& renderData);
    
    ref<Texture> createNeighborOffsetTexture(uint32_t sampleCount);

    // Internal state

    /// Current scene.
    ref<Scene> mpScene;
    /// GPU sample generator.
    ref<SampleGenerator> mpSampleGenerator;
    
    // Configuration

    /// User settings, composed of shared configs (Shared/Configs) plus this pass's own.
    struct Options
    {
        TransientHistogramConfig histogram;
        PathTracingConfig pathTracing;
        ReSTIRConfig restir;
        bool useBinReuse = false; ///< Add adjacent bins of the same pixel as spatial reuse candidates.
    };
    Options mOptions;


    // Runtime data

    // Time Gate Data


    float mTcurr;


    // Transient Shift Mapping


    // Temporal reuse (static geometry and light, moving camera).
    bool mTemporalHistoryValid = false;
    uint2 mTemporalHistoryDimensions = uint2(0);
    float3 mPreviousCameraPosition = float3(0.f);
    float3 mPreviousLaserPosition = float3(0.f);
    float3 mPreviousLaserDirection = float3(0.f);
    float3 mPreviousLaserPower = float3(0.f);
    float mPreviousLaserCosAngle = 0.f;
    ref<Texture> mpTemporalVBuffer;
    bool mNeedToClearHistogram = false;


    float3 mLaserPosition = float3(0.0);
    float3 mLaserDirection = float3(1.0);
    float3 mLaserPower = float3(1.0);
    float mLaserCosAngle = 0.0;

    

    /// Frame count since scene was loaded.
    uint mFrameCount = 0;
    uint mTimeGateFrameCount = 0;

    uint mRandomSeed = 0;
    bool mOptionsChanged = false;


    EmissiveLightSamplerType emissiveSampler = EmissiveLightSamplerType::LightBVH;  ///< Emissive light sampler to use for NEE.
    std::unique_ptr<EmissiveLightSampler> mpEmissiveSampler;    ///< Emissive light sampler or nullptr if not used.
    mutable LightBVHSampler::Options mLightBVHOptions;          ///< Current options for the light BVH sampler.
    
    
    ref<Texture>                     mpNeighborOffsets;
    
    // Ray tracing program.
    ref<ComputePass> mpComputePass;

    ref<ComputePass>                mpReflectTypes;                         ///< Helper for reflecting structured buffer types.
    ref<ComputePass>                mpSpatialReusePass;
    ref<ComputePass>                mpFinalEvaluatePass;
    
    // Reservoirs and reconnection data for ReSTIR
    ref<Buffer>                     mpCurrReservoirs;                       ///< The current reservoir stores the canonical sample from the initial candidate generation pass.
    ref<Buffer>                     mpPrevReservoirs;                       ///< Scratch reservoir storage for spatial iterations.
    ref<Buffer>                     mpTempReservoirs;                       ///< Scratch reservoir storage for spatial iterations.
    
    
};
