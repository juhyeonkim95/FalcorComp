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
#include "Utils/Debug/PixelDebug.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include "Rendering/Materials/TexLODTypes.slang"
#include "Rendering/Utils/PixelStats.h"

#include "Params.slang"

using namespace Falcor;

/**
 * Render pass that blits an input texture to an output texture.
 *
 * This pass is useful for format conversion.
 */
class ReSTIRPTPass : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ReSTIRPTPass, "ReSTIRPTPass", "Path tracer using DXR 1.1 TraceRayInline");


    static ref<ReSTIRPTPass> create(ref<Device> pDevice, const Properties& props) { 
        return make_ref<ReSTIRPTPass>(pDevice, props); 
    }

    ReSTIRPTPass(ref<Device> pDevice, const Properties& props);

    virtual void setProperties(const Properties& props) override;
    virtual Properties getProperties() const override;
    Properties getSpecializedProperties() const;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override;
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }


    // Scripting functions
    PixelStats& getPixelStats() { return *mpPixelStats; }
    static void registerBindings(pybind11::module& m);

private:
    void parseProperties(const Properties& props);
    void validateOptions();
    void resetPrograms();
    void updatePrograms();

    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);
    void preparePathTracer(const RenderData& renderData);

    bool beginFrame(RenderContext* pRenderContext, const RenderData& renderData);
    void endFrame(RenderContext* pRenderContext, const RenderData& renderData);
    void generatePaths(RenderContext* pRenderContext, const RenderData& renderData, int sampleId = 0);
    void tracePass(RenderContext* pRenderContext, const RenderData& renderData, const ref<ComputePass>& pass, const std::string& passName, int sampleId);
    void PathReusePass(RenderContext* pRenderContext, uint32_t restir_i, const RenderData& renderData, bool temporalReuse = false, int spatialRoundId = 0, bool isLastRound = false);
    void PathRetracePass(RenderContext* pRenderContext, uint32_t restir_i, const RenderData& renderData, bool temporalReuse = false, int spatialRoundId = 0);

    void setFrameDim(const uint2 frameDim);
    void resetLighting();
    void prepareMaterials(RenderContext* pRenderContext);
    bool prepareLighting(RenderContext* pRenderContext);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData, bool isPathTracer, bool isPathGenerator) const;    
    void setNRDData(const ShaderVar& var, const RenderData& renderData) const;


    bool renderRenderingUI(Gui::Widgets& widget);
    bool renderDebugUI(Gui::Widgets& widget);
    void renderStatsUI(Gui::Widgets& widget);


    ref<Texture> createNeighborOffsetTexture(uint32_t sampleCount);


    /** Static configuration. Changing any of these options require shader recompilation.
    */
   struct StaticParams
   {
       // Rendering parameters
       uint32_t    samplesPerPixel = 1;                        ///< Number of samples (paths) per pixel, unless a sample density map is used.
       uint32_t    candidateSamples = 1;
       uint32_t    maxSurfaceBounces = 9;                      ///< Max number of surface bounces (diffuse + specular + transmission), up to kMaxPathLenth.
       uint32_t    maxDiffuseBounces = -1;                     ///< Max number of diffuse bounces (0 = direct only), up to kMaxBounces. This will be initialized at startup.
       uint32_t    maxSpecularBounces = -1;                    ///< Max number of specular bounces (0 = direct only), up to kMaxBounces. This will be initialized at startup.
       uint32_t    maxTransmissionBounces = -1;                ///< Max number of transmission bounces (0 = none), up to kMaxBounces. This will be initialized at startup.
       uint32_t    sampleGenerator = SAMPLE_GENERATOR_TINY_UNIFORM; ///< Pseudorandom sample generator type.
       bool        adjustShadingNormals = false;               ///< Adjust shading normals on secondary hits.
       bool        useBSDFSampling = true;                     ///< Use BRDF importance sampling, otherwise cosine-weighted hemisphere sampling.
       bool        useNEE = true;                              ///< Use next-event estimation (NEE). This enables shadow ray(s) from each path vertex.
       bool        useMIS = true;                              ///< Use multiple importance sampling (MIS) when NEE is enabled.
       bool        useRussianRoulette = false;                 ///< Use russian roulette to terminate low throughput paths.
       bool        useAlphaTest = true;                        ///< Use alpha testing on non-opaque triangles.
       uint32_t    maxNestedMaterials = 2;                     ///< Maximum supported number of nested materials.
       bool        useLightsInDielectricVolumes = false;       ///< Use lights inside of volumes (transmissive materials). We typically don't want this because lights are occluded by the interface.
       bool        limitTransmission = false;                  ///< Limit specular transmission by handling reflection/refraction events only up to a given transmission depth.
       uint32_t    maxTransmissionReflectionDepth = 0;         ///< Maximum transmission depth at which to sample specular reflection.
       uint32_t    maxTransmissionRefractionDepth = 0;         ///< Maximum transmission depth at which to sample specular refraction (after that, IoR is set to 1).
       bool        disableCaustics = false;                    ///< Disable sampling of caustics.
       bool        disableDirectIllumination = true;          ///< Disable all direct illumination.
       TexLODMode  primaryLodMode = TexLODMode::Mip0;          ///< Use filtered texture lookups at the primary hit.
       ColorFormat colorFormat = ColorFormat::LogLuvHDR;       ///< Color format used for internal per-sample color and denoiser buffers.
       MISHeuristic misHeuristic = MISHeuristic::Balance;      ///< MIS heuristic.
       float       misPowerExponent = 2.f;                     ///< MIS exponent for the power heuristic. This is only used when 'PowerExp' is chosen.
       EmissiveLightSamplerType emissiveSampler = EmissiveLightSamplerType::Uniform;  ///< Emissive light sampler to use for NEE.

       bool        useDeterministicBSDF = true;                    ///< Evaluate all compatible lobes at BSDF sampling time.

       ReSTIRMISKind    spatialMisKind = ReSTIRMISKind::Pairwise;
       ReSTIRMISKind    temporalMisKind = ReSTIRMISKind::Talbot;

       ShiftMapping    shiftStrategy = ShiftMapping::Hybrid;
       bool            temporalUpdateForDynamicScene = false;

       PathSamplingMode pathSamplingMode = PathSamplingMode::PathTracing;

       bool            separatePathBSDF = true;

       bool            rcDataOfflineMode = false;

       // Denoising parameters
       bool        useNRDDemodulation = true;                  ///< Global switch for NRD demodulation.

       DefineList getDefines(const ReSTIRPTPass& owner) const;
   };


   void Init()
   {
       mStaticParams = StaticParams();
       mParams = RestirPathTracerParams();
       mEnableTemporalReuse = true;
       mEnableSpatialReuse = true;
       mSpatialReusePattern = SpatialReusePattern::Default;
       mPathReusePattern = PathReusePattern::NRooksShift;
       mSmallWindowRestirWindowRadius = 2;
       mSpatialNeighborCount = 3;
       mSpatialReuseRadius = 20.f;
       mNumSpatialRounds = 1;
       mEnableTemporalReprojection = false;
       mUseMaxHistory = true;
       mUseDirectLighting = true;
       mTemporalHistoryLength = 20;
       mNoResamplingForTemporalReuse = false;
   }

    // Configuration
    RestirPathTracerParams          mParams;                    ///< Runtime path tracer parameters.
    StaticParams                    mStaticParams;              ///< Static parameters. These are set as compile-time constants in the shaders.
    LightBVHSampler::Options        mLightBVHOptions;           ///< Current options for the light BVH sampler.
    
    bool                            mEnabled = true;            ///< Switch to enable/disable the path tracer. When disabled the pass outputs are cleared.
    RenderPassHelpers::IOSize       mOutputSizeSelection = RenderPassHelpers::IOSize::Default;  ///< Selected output size.
    uint2                           mFixedOutputSize = { 512, 512 };                            ///< Output size in pixels when 'Fixed' size is selected.

    // Internal state
    ref<IScene>                     mpScene;                    ///< The current scene, or nullptr if no scene loaded.
    ref<SampleGenerator>            mpSampleGenerator;          ///< GPU pseudo-random sample generator.
    std::unique_ptr<EnvMapSampler>  mpEnvMapSampler;            ///< Environment map sampler or nullptr if not used.
    std::unique_ptr<EmissiveLightSampler> mpEmissiveSampler;    ///< Emissive light sampler or nullptr if not used.
    // std::unique_ptr<RTXDI>          mpRTXDI;                    ///< RTXDI sampler for direct illumination or nullptr if not used.
    std::unique_ptr<PixelStats>     mpPixelStats;               ///< Utility class for collecting pixel stats.
    std::unique_ptr<PixelDebug>     mpPixelDebug;               ///< Utility class for pixel debugging (print in shaders).
    
    sigs::Connection                mUpdateFlagsConnection; ///< Connection to the UpdateFlags signal.
    /// SceneUpdateFlags accumulated since last `beginFrame()`
    IScene::UpdateFlags             mUpdateFlags = IScene::UpdateFlags::None;

    ref<ParameterBlock>             mpPathTracerBlock;          ///< Parameter block for the path tracer.

    // internal below
    bool                            mRecompile = false;         ///< Set to true when program specialization has changed.
    bool                            mVarsChanged = true;        ///< This is set to true whenever the program vars have changed and resources need to be rebound.
    bool                            mOptionsChanged = false;    ///< True if the config has changed since last frame.
    bool                            mGBufferAdjustShadingNormals = false; ///< True if GBuffer/VBuffer has adjusted shading normals enabled.
    bool                            mOutputTime = false;        ///< True if time data should be generated as output.
    bool                            mOutputNRDData = false;     ///< True if NRD diffuse/specular data should be generated as outputs.
    bool                            mEnableRayStats = false;      ///< Set to true when the stats tab in the UI is open. This may negatively affect performance.

    uint64_t                        mAccumulatedRayCount = 0;
    uint64_t                        mAccumulatedClosestHitRayCount = 0;
    uint64_t                        mAccumulatedShadowRayCount = 0;

    // params below
    bool                            mEnableTemporalReuse = true;
    bool                            mEnableSpatialReuse = true;
    SpatialReusePattern             mSpatialReusePattern = SpatialReusePattern::Default;
    PathReusePattern                mPathReusePattern = PathReusePattern::Block;
    uint32_t                        mSmallWindowRestirWindowRadius = 2;
    int                             mSpatialNeighborCount = 3;
    float                           mSpatialReuseRadius = 20.f;
    int                             mNumSpatialRounds = 1;

    bool                            mEnableTemporalReprojection = true;
    bool                            mFeatureBasedRejection = true;

    bool                            mUseMaxHistory = true;

    int                             mReservoirFrameCount = 0; // internal

    bool                            mUseDirectLighting = true;

    int                             mTemporalHistoryLength = 20;
    bool                            mNoResamplingForTemporalReuse = false;
    int                             mSeedOffset = 0;


    bool mResetRenderPassFlags = false;

    ref<ComputePass>          mpSpatialReusePass;      ///< Merges reservoirs.
    ref<ComputePass>          mpTemporalReusePass;      ///< Merges reservoirs.
    ref<ComputePass>          mpComputePathReuseMISWeightsPass;

    ref<ComputePass>          mpSpatialPathRetracePass;
    ref<ComputePass>          mpTemporalPathRetracePass;

    ref<ComputePass>          mpGeneratePaths;                ///< Fullscreen compute pass generating paths starting at primary hits.
    ref<ComputePass>          mpTracePass;                    ///< Main tracing pass.

    ref<ComputePass>          mpReflectTypes;             ///< Helper for reflecting structured buffer types.

    ref<Fence>              mpFence;            ///< GPU fence for synchronizing stats readback.

    // Data
    ref<Buffer>               mpCounters;                 ///< Atomic counters (32-bit).
    ref<Buffer>               mpCountersReadback;         ///< Readback buffer for the counters for stats gathering.

    ref<Buffer>               mpOutputReservoirs;               ///< Output paths from the path sampling stage.
    // enable multiple temporal reservoirs for spp > 1 (multiple ReSTIR chains)
    std::vector<ref<Buffer>>               mpTemporalReservoirs;               ///< Output paths from the path sampling stage.
    ref<Buffer>               mReconnectionDataBuffer;
    ref<Buffer>               mPathReuseMISWeightBuffer;

    ref<Texture>              mpTemporalVBuffer;

    ref<Texture>              mpNeighborOffsets;

    ref<Buffer>               mNRooksPatternBuffer;
};
