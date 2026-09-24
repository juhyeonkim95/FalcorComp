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
#include "../Shared/TimeGated/TimeGatedOptions.h"

using namespace Falcor;


enum class ShiftmapMethod
{
    NO = 0,
    LOCAL_TANGENT_SURFACE = 1,
    BARYCENTRIC = 2,
    RAY_TRACE_HEMISPHERE = 3,
    AREA_ADAPTIVE = 4,
    RAY_TRACE_CHART = 5,
};

static const std::unordered_map<std::string, ShiftmapMethod> ShiftmapMethodTable = {
    {"no", ShiftmapMethod::NO},
    {"local_tangent", ShiftmapMethod::LOCAL_TANGENT_SURFACE},
    {"barycentric", ShiftmapMethod::BARYCENTRIC},
    {"ray_trace", ShiftmapMethod::RAY_TRACE_HEMISPHERE},
    {"area_adaptive", ShiftmapMethod::AREA_ADAPTIVE},
    {"ray_trace_chart", ShiftmapMethod::RAY_TRACE_CHART}
};

enum class GaugeMode
{
    CONSTANT = 0,
    ORTHO_GRAD_START = 1,
    ORTHO_AVG_GRAD = 2,
};

static const std::unordered_map<std::string, GaugeMode> GaugeModeTable = {
    {"constant", GaugeMode::CONSTANT},
    {"grad", GaugeMode::ORTHO_GRAD_START},
    {"avg_grad", GaugeMode::ORTHO_AVG_GRAD}
};

/// ReSTIR settings: reuse, path-length-aware shift mapping and the wide (shrink-mapped) gate.
struct ReSTIRConfig
{
    uint spatialReuseIteration = 1;
    uint spatialReuseNeighborCount = 5;
    float spatialReuseGatherRadius = 10.0f;   ///< Pixels.
    bool useTemporalReuse = true;
    float temporalHistoryLength = 20.0f;      ///< History cap in frames of samples; 0 ignores it, negative is uncapped.
    bool isSceneDynamic = false;              ///< Keep the history when the light moves, re-evaluating reused paths.

    ShiftmapMethod shiftmapMethod = ShiftmapMethod::NO;
    GaugeMode gaugeMode = GaugeMode::CONSTANT;
    float2 gaugeAxis = float2(1, 0);
    uint newtonMaxIteration = 5;
    float newtonRelativeTolerance = 0.01f;
    float reconnectionRoughnessThreshold = 0.25f; ///< Both vertices of a reconnection segment must be rougher.
    bool debugNewtonIterations = false;       ///< Adds the newtonStatistics and mappingDistance outputs.

    float timeGateWindowRough = 0.0f;         ///< Direct sampling: wide gate traced by some paths and shrunk into the gate.
    float roughTimeGateSampleRatio = 0.5f;    ///< Fraction of paths traced with the wide gate.
    uint2 laserHitVBufferRes = uint2(256, 256);

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "spatialReuseIteration")
            spatialReuseIteration = value;
        else if (key == "spatialReuseNeighborCount")
            spatialReuseNeighborCount = value;
        else if (key == "spatialReuseGatherRadius")
            spatialReuseGatherRadius = value;
        else if (key == "useTemporalReuse")
            useTemporalReuse = value;
        else if (key == "temporalHistoryLength")
            temporalHistoryLength = value;
        else if (key == "isSceneDynamic")
            isSceneDynamic = value;
        else if (key == "shiftmapMethod")
            shiftmapMethod = parseEnumProperty(ShiftmapMethodTable, std::string(value), key);
        else if (key == "gaugeMode")
            gaugeMode = parseEnumProperty(GaugeModeTable, std::string(value), key);
        else if (key == "gaugeAxis")
            gaugeAxis = value;
        else if (key == "NewtonMaxIteration")
            newtonMaxIteration = value;
        else if (key == "NewtonRelativeTolerance")
            newtonRelativeTolerance = value;
        else if (key == "specularRoughnessThreshold")
            reconnectionRoughnessThreshold = value;
        else if (key == "debugNewtonIterations")
            debugNewtonIterations = value;
        else if (key == "timeGateWindowRough")
            timeGateWindowRough = value;
        else if (key == "roughTimeGateSampleRatio")
            roughTimeGateSampleRatio = value;
        else if (key == "laserHitVBufferRes")
            laserHitVBufferRes = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["spatialReuseIteration"] = spatialReuseIteration;
        props["spatialReuseNeighborCount"] = spatialReuseNeighborCount;
        props["spatialReuseGatherRadius"] = spatialReuseGatherRadius;
        props["useTemporalReuse"] = useTemporalReuse;
        props["temporalHistoryLength"] = temporalHistoryLength;
        props["isSceneDynamic"] = isSceneDynamic;
        props["shiftmapMethod"] = enumPropertyName(ShiftmapMethodTable, shiftmapMethod);
        props["gaugeMode"] = enumPropertyName(GaugeModeTable, gaugeMode);
        props["gaugeAxis"] = gaugeAxis;
        props["NewtonMaxIteration"] = newtonMaxIteration;
        props["NewtonRelativeTolerance"] = newtonRelativeTolerance;
        props["specularRoughnessThreshold"] = reconnectionRoughnessThreshold;
        props["debugNewtonIterations"] = debugNewtonIterations;
        props["timeGateWindowRough"] = timeGateWindowRough;
        props["roughTimeGateSampleRatio"] = roughTimeGateSampleRatio;
        props["laserHitVBufferRes"] = laserHitVBufferRes;
    }
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
    void prepareVars();
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);
    void spatialReuse(RenderContext* pRenderContext, const RenderData& renderData);
    
    ref<Texture> createNeighborOffsetTexture(uint32_t sampleCount);

    // Internal state

    /// Current scene.
    ref<Scene> mpScene;
    /// GPU sample generator.
    ref<SampleGenerator> mpSampleGenerator;
    
    // Configuration

    /// User settings, grouped as in TimeGatedOptions.h plus the ReSTIR ones.
    struct Options
    {
        TimeGateConfig timeGate;
        SamplingConfig sampling;
        PathTracingConfig pathTracing;
        ReSTIRConfig restir;
    };
    Options mOptions;

    // Runtime data

    float mTcurr = 0.f; ///< Current gate center.
    float mTprev = 0.f; ///< Previous frame's gate center.

    float3 mLaserPosition = float3(0.0);
    float3 mLaserDirection = float3(1.0);
    float3 mLaserPower = float3(1.0);
    float mLaserCosAngle = 0.0;

    float3 mLaserPrevPosition;
    float3 mLaserPrevDirection;

    /// Frame count since scene was loaded.
    uint mFrameCount = 0;
    uint mTimeGateFrameCount = 0;
    uint mPrevTimeGateFrameCount = 0;

    uint mRandomSeed = 0;
    bool mOptionsChanged = false;
    bool mGateMoved = false; ///< The gate shifted: restart accumulation but keep the ReSTIR history.
    std::string mUIWarning;  ///< Why the last UI edit was rejected.

    bool mTemporalHistoryValid = false;
    uint2 mTemporalHistoryDimensions = uint2(0);
    float3 mPreviousCameraPosition = float3(0.f);
    float3 mPreviousLaserPower = float3(0.f);
    float mPreviousLaserCosAngle = 0.f;
    
    EmissiveLightSamplerType emissiveSampler = EmissiveLightSamplerType::LightBVH;  ///< Emissive light sampler to use for NEE.
    std::unique_ptr<EmissiveLightSampler> mpEmissiveSampler;    ///< Emissive light sampler or nullptr if not used.
    mutable LightBVHSampler::Options mLightBVHOptions;          ///< Current options for the light BVH sampler.
    
    
    ref<Texture>                     mpNeighborOffsets;
    
    // Ray tracing program.
    ref<ComputePass> mpComputePass;

    ref<ComputePass>                mpReflectTypes;                         ///< Helper for reflecting structured buffer types.
    ref<ComputePass>                mpSpatialReusePass;
    
    // Reservoirs and reconnection data for ReSTIR
    ref<Buffer>                     mpCurrReservoirs;                       ///< The current reservoir stores the canonical sample from the initial candidate generation pass.
    ref<Buffer>                     mpPrevReservoirs;                       ///< The previous reservoir stores all the samples from the previous frame.
    
    ref<Texture> mpTemporalVBuffer;
};
