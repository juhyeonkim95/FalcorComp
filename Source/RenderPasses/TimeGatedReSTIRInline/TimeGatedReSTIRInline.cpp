/***************************************************************************
 # Copyright (c) 2015-24, NVIDIA CORPORATION. All rights reserved.
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
#include "TimeGatedReSTIRInline.h"
#include <algorithm>
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regTimeGatedReSTIRInline(pybind11::module& m)
{
    pybind11::class_<TimeGatedReSTIRInline, RenderPass, ref<TimeGatedReSTIRInline>> pass(m, "TimeGatedReSTIRInline");
    // pass.def_property("m", &MinimalTimeGatedPathTracer::isEnabled, &MinimalTimeGatedPathTracer::setEnabled);
    pass.def("increment_time_gate_frame", &TimeGatedReSTIRInline::incrementTimeGateFrame);
    pass.def("set_time_gate_info", &TimeGatedReSTIRInline::setTimeGateInfo);
}


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TimeGatedReSTIRInline>();
    ScriptBindings::registerBinding(regTimeGatedReSTIRInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TimeGatedReSTIRInline/InitialSampleGeneration.cs.slang";
const char kReflectTypesFile[] = "RenderPasses/TimeGatedReSTIRInline/ReflectTypes.cs.slang";
const char kSpatialReuseFile[] = "RenderPasses/TimeGatedReSTIRInline/SpatialReuse.cs.slang";
const char kInputViewDir[] = "viewW";
const char kInputMotionVectors[] = "mvec";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputMotionVectors,  "gMotionVector",   "Motion vector buffer (float format)", true /* optional */ },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kLaserInputChannels = {
    // 1 x 1 laser hit buffer
    { "laservbuffer",  "gLaserVBuffer",     "Laser visibility buffer in packed format", true /* optional */ },
    { "laserviewW",    "gLaserViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kLaserHitInputChannels = {
    // shadow map from laser hit point
    { "laserhitvbuffer",  "gLaserHitVBuffer",     "Laser visibility buffer in packed format", true /* optional */ },
    { "laserhitviewW",    "gLaserHitViewW",       "World-space view direction (xyz float format)", true /* optional */ },
    { "laserhitdepth",    "gLaserHitDepth",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kOutputChannels = {
    // clang-format off
    { "color",          "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const ChannelList kDebugOutputChannels = {
    { "newtonStatistics", "gNewtonStatistics", "Mapping successes, actual successes, attempts, iteration sum", false, ResourceFormat::RGBA32Uint },
    { "mappingDistance", "gMappingDistance", "Sum of coordinate and world displacement for successful solves", false, ResourceFormat::RG32Float },
};

const char kRandomSeed[] = "randomSeed";
const uint32_t kNeighborOffsetCount = 8192;
} // namespace

TimeGatedReSTIRInline::TimeGatedReSTIRInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void TimeGatedReSTIRInline::incrementTimeGateFrame()
{
    mPrevTimeGateFrameCount = mTimeGateFrameCount;
    mTimeGateFrameCount += 1;
}

void TimeGatedReSTIRInline::setTimeGateInfo(float timeMin, float timeMax, uint timeBin)
{
    mOptions.timeGate.timeMin = timeMin;
    mOptions.timeGate.timeMax = timeMax;
    mOptions.timeGate.timeBin = timeBin;
}


// void TimeGatedReSTIRInline::incrementTimeGateFrame()
// {
//     mPrevTimeGateFrameCount = mTimeGateFrameCount;
//     mTimeGateFrameCount += 1;
// }

void TimeGatedReSTIRInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.timeGate.parse(key, value) || mOptions.sampling.parse(key, value) ||
            mOptions.pathTracing.parse(key, value) || mOptions.restir.parse(key, value))
            continue;
        if (key == kRandomSeed)
            mRandomSeed = value;
        else
            logWarning("Unknown property '{}' in TimeGatedReSTIRInline properties.", key);
    }
    mOptions.timeGate.applyTimeCenter(props);
    if (mOptions.sampling.samplingMethod != TimeGatedSamplingMethod::DIRECT &&
        mOptions.sampling.triSampler != EmissiveLightSamplerType::Uniform && mOptions.sampling.triSampler != EmissiveLightSamplerType::LightBVH)
        FALCOR_THROW("Ellipsoidal initial sampling requires the Uniform or LightBVH triangle sampler.");
    // Dynamic suffix replay reconstructs BSDF steps after y only. An ellipsoidal candidate
    // inserts x or y (both reevaluated exactly); inserting a vertex after y needs a walk
    // that reaches y and continues, i.e. maxBounces >= 4.
    if (mOptions.restir.isSceneDynamic && mOptions.sampling.samplingMethod != TimeGatedSamplingMethod::DIRECT && mOptions.pathTracing.maxBounces > 3)
        FALCOR_THROW("Ellipsoidal initial sampling with isSceneDynamic=true requires maxBounces <= 3.");
}

Properties TimeGatedReSTIRInline::getProperties() const
{
    Properties props;
    mOptions.timeGate.serialize(props);
    mOptions.sampling.serialize(props);
    mOptions.pathTracing.serialize(props);
    mOptions.restir.serialize(props);
    props[kRandomSeed] = mRandomSeed;
    return props;
}

RenderPassReflection TimeGatedReSTIRInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassInputs(reflector, kLaserHitInputChannels, ResourceBindFlags::ShaderResource, mOptions.restir.laserHitVBufferRes);
    addRenderPassOutputs(reflector, kOutputChannels);
    if (mOptions.restir.debugNewtonIterations) addRenderPassOutputs(reflector, kDebugOutputChannels);

    return reflector;
}

DefineList TimeGatedReSTIRInline::getShaderDefines(const RenderData& renderData) const{
    DefineList defines;

    // Specialize away the entire extra reservoir/shift path when it has no samples.
    uint32_t wideSampleCount = 0;
    if (mOptions.sampling.samplingMethod == TimeGatedSamplingMethod::DIRECT && mOptions.pathTracing.samplesPerPixel > 0 &&
        std::isfinite(mOptions.restir.timeGateWindowRough) && mOptions.timeGate.timeGateWindow > 0.f &&
        mOptions.restir.timeGateWindowRough > mOptions.timeGate.timeGateWindow && std::isfinite(mOptions.restir.roughTimeGateSampleRatio) &&
        (mOptions.timeGate.timeGateMode == TimeGateMode::BOX || mOptions.timeGate.timeGateMode == TimeGateMode::TENT))
    {
        const float ratio = std::clamp(mOptions.restir.roughTimeGateSampleRatio, 0.f, 1.f);
        wideSampleCount = std::min(uint32_t(float(mOptions.pathTracing.samplesPerPixel) * ratio), mOptions.pathTracing.samplesPerPixel);
    }
    defines.add("USE_SHRINK_MAPPING", wideSampleCount > 0 ? "1" : "0");
    defines.add("SHRINK_WIDE_SAMPLE_COUNT", std::to_string(wideSampleCount));

    defines.add("DEBUG_NEWTON_ITERATIONS", mOptions.restir.debugNewtonIterations ? "1" : "0");
    defines.add("MAX_BOUNCES", std::to_string(mOptions.pathTracing.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.pathTracing.computeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("IS_SCENE_DYNAMIC", mOptions.restir.isSceneDynamic ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.pathTracing.isLightSourceLaser ? "1" : "0");
    defines.add("USE_TEMPORAL_REUSE", mOptions.restir.useTemporalReuse ? "1" : "0");
    
    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.sampling.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::DIRECT));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL));
    defines.add("ELLIPSOIDAL_DIRECT_MIS", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS));
    defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)mOptions.restir.shiftmapMethod));
    defines.add("SHIFT_MAPPING_GAUGE_MODE", std::to_string((uint32_t)mOptions.restir.gaugeMode));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserHitInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    return defines;
}

void TimeGatedReSTIRInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();

    if(mpEmissiveSampler){
        mpEmissiveSampler->bindShaderData(var["emissiveSampler"]);
    }

    var["prevReservoirs"] = mpPrevReservoirs;
    var["currReservoirs"] = mpCurrReservoirs;

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gRandomSeed"] = mRandomSeed;
    
    var["CB"]["gFrameDim"] = targetDim;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["gLaserHitVBufferRes" ] = mOptions.restir.laserHitVBufferRes;
    var["CB"]["specularRoughnessThreshold" ] = mOptions.restir.reconnectionRoughnessThreshold;
    var["CB"]["specularRoughnessThresholdEllipsoid" ] = mOptions.sampling.ellipsoidRoughnessThreshold;
    
    // transients
    // if(mOptions.pathTracing.laserCollocated && mpScene){
    //     var["Laser_CB"]["laserOrigin"] = mpScene->getCamera()->getPosition();
    //     var["Laser_CB"]["laserDirection"] = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    // } else {
    //     var["Laser_CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
    //     var["Laser_CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    // }
    var["Laser_CB"]["laserOrigin"] = mLaserPosition;
    var["Laser_CB"]["laserDirection"] = mLaserDirection;
    var["Laser_CB"]["laserPrevOrigin"] = mLaserPrevPosition;
    var["Laser_CB"]["laserPrevDirection"] = mLaserPrevDirection;
    // printf("1: %.4f, %.4f, %.4f\n", mLaserPosition.x, mLaserPosition.y, mLaserPosition.z);
    // printf("2: %.4f, %.4f, %.4f\n", mLaserPrevPosition.x, mLaserPrevPosition.y, mLaserPrevPosition.z);
    
    
    var["Laser_CB"]["laserPower"] = mLaserPower;
    var["Laser_CB"]["laserCosAngle"] = mLaserCosAngle;
    
    var["CB"]["samplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gTemporalHistoryLength"] = mOptions.restir.temporalHistoryLength;
    var["CB"]["gRoughTimeGateSampleRatio"] = mOptions.restir.roughTimeGateSampleRatio;

    var["TimeGate"]["time_gate_window"] = mOptions.timeGate.timeGateWindow;
    var["TimeGate"]["time_gate_window_rough"] = mOptions.restir.timeGateWindowRough;
    var["TimeGate"]["time_gate_mode"] = uint(mOptions.timeGate.timeGateMode);

    // if(mFrameCount == mOptions.timeGate.timeBin){
    //     mFrameCount = 0;
    // }
    // printf("Time Difference: %.5f \n", (mTcurr - mTprev));

    var["TimeGate"]["tcurr"] = mTcurr;
    var["TimeGate"]["tprev"] = mTprev;

    var["Shiftmap_CB"]["gGaugeAxis"] = mOptions.restir.gaugeAxis;
    var["Shiftmap_CB"]["gGaugeMode"] = uint(mOptions.restir.gaugeMode);
    var["Shiftmap_CB"]["gShiftMappingMethod"] = uint(mOptions.restir.shiftmapMethod);
    var["Shiftmap_CB"]["gNewtonMaxIteration"] = mOptions.restir.newtonMaxIteration;
    var["Shiftmap_CB"]["gNewtonRelativeTolerance"] = mOptions.restir.newtonRelativeTolerance;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kLaserInputChannels)
        bind(channel);
    for (auto channel : kLaserHitInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);
    if (mOptions.restir.useTemporalReuse)
    {
        var["gTemporalVBuffer"] = mpTemporalVBuffer;
        var["CB"]["gTemporalHistoryValid"] = mTemporalHistoryValid;
        var["CB"]["gPreviousCameraPosition"] = mPreviousCameraPosition;
        if (mOptions.restir.isSceneDynamic)
        {
            var["Laser_CB"]["laserPrevPower"] = mPreviousLaserPower;
            var["Laser_CB"]["laserPrevCosAngle"] = mPreviousLaserCosAngle;
        }
    }
}

void TimeGatedReSTIRInline::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Specialize program.
    mpSpatialReusePass->getProgram()->addDefines(getShaderDefines(renderData));

    auto& dict = renderData.getDictionary();
    auto rootvar = mpSpatialReusePass->getRootVar();
    auto var = rootvar["CB"]["gSpatialReuse"];
    
    if(mpEmissiveSampler){
        mpEmissiveSampler->bindShaderData(rootvar["Shiftmap_CB"]["emissiveSamplerShiftmap"]);
    }

    // bindShaderData(var["gSpatialReuse"], renderData);
    const uint2 targetDim = renderData.getDefaultTextureDims();

    var["gFrameCount"] = mFrameCount;
    var["gFrameDim"] = targetDim;
    var["neighborOffsets"] = mpNeighborOffsets;
    var["neighborCount"] = mOptions.restir.spatialReuseNeighborCount;
    var["gatherRadius"] = mOptions.restir.spatialReuseGatherRadius;
    var["useBinReuse"] = false; // A time gate has a single bin.
    var["specularRoughnessThreshold"] = mOptions.restir.reconnectionRoughnessThreshold;
    
    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kLaserInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);
    if (mOptions.restir.debugNewtonIterations)
        for (auto channel : kDebugOutputChannels) bind(channel);

    rootvar["TimeGate"]["time_gate_window"] = mOptions.timeGate.timeGateWindow;
    rootvar["TimeGate"]["time_gate_window_rough"] = mOptions.restir.timeGateWindowRough;
    rootvar["TimeGate"]["time_gate_mode"] = uint(mOptions.timeGate.timeGateMode);
    rootvar["TimeGate"]["tcurr"] = mTcurr;
    rootvar["TimeGate"]["tprev"] = mTprev;

    // transients
    rootvar["Laser_CB"]["laserOrigin"] = mLaserPosition;
    rootvar["Laser_CB"]["laserDirection"] = mLaserDirection;
    rootvar["Laser_CB"]["laserPower"] = mLaserPower;
    rootvar["Laser_CB"]["laserCosAngle"] = mLaserCosAngle;
    
    // if(mOptions.pathTracing.laserCollocated && mpScene){
    //     rootvar["Laser_CB"]["laserOrigin"] = mpScene->getCamera()->getPosition();
    //     rootvar["Laser_CB"]["laserDirection"] = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    // } else {
    //     rootvar["Laser_CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
    //     rootvar["Laser_CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    // }
    // rootvar["Laser_CB"]["laserPower"] = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    // rootvar["Laser_CB"]["laserCosAngle"] = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;
    
    rootvar["Shiftmap_CB"]["gGaugeAxis"] = mOptions.restir.gaugeAxis;
    rootvar["Shiftmap_CB"]["gGaugeMode"] = uint(mOptions.restir.gaugeMode);
    rootvar["Shiftmap_CB"]["gShiftMappingMethod"] = uint(mOptions.restir.shiftmapMethod);
    rootvar["Shiftmap_CB"]["gNewtonMaxIteration"] = mOptions.restir.newtonMaxIteration;
    rootvar["Shiftmap_CB"]["gNewtonRelativeTolerance"] = mOptions.restir.newtonRelativeTolerance;

    // Clear diagnostics once per frame; spatial iterations add to these buffers.
    // Keep initial RGB intact, including when spatial iteration count is zero.
    if (mOptions.restir.debugNewtonIterations)
    {
        pRenderContext->clearUAV(renderData.getTexture("newtonStatistics")->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(renderData.getTexture("mappingDistance")->getUAV().get(), float4(0.f));
    }

    for(uint iteration=0; iteration < mOptions.restir.spatialReuseIteration; iteration++){
        std::swap(mpCurrReservoirs, mpPrevReservoirs);
        var["gRandomSeed"] = mRandomSeed++;
        var["prevReservoirs"] = mpPrevReservoirs;
        var["currReservoirs"] = mpCurrReservoirs;
        mpSpatialReusePass->execute(pRenderContext, {targetDim.x, targetDim.y, 1});
    }
}

void TimeGatedReSTIRInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{

    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        mTemporalHistoryValid = false;
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }
    if (mGateMoved)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mGateMoved = false;
    }

    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
        mTemporalHistoryValid = false;
        for (auto it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        if (mOptions.restir.debugNewtonIterations)
            for (auto channel : kDebugOutputChannels)
                if (auto texture = renderData.getTexture(channel.name)) pRenderContext->clearTexture(texture.get());
        return;
    }

    // set laser position
    if(mOptions.pathTracing.laserCollocated){
        mLaserPosition = mpScene->getCamera()->getPosition();
        mLaserDirection = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    } else {
        mLaserPosition = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
        mLaserDirection = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    }
    mLaserPower = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    mLaserCosAngle = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;

    // Dynamic mode supports moving cameras/lights, but not geometry or material changes.
    const auto updates = mpScene->getUpdates();
    const auto cameraUpdates = IScene::UpdateFlags::CameraMoved |
        IScene::UpdateFlags::CameraPropertiesChanged | IScene::UpdateFlags::CameraSwitched;
    auto allowedUpdates = cameraUpdates;
    if (mOptions.restir.isSceneDynamic)
        allowedUpdates |= IScene::UpdateFlags::LightsMoved | IScene::UpdateFlags::LightIntensityChanged |
            IScene::UpdateFlags::LightPropertiesChanged | IScene::UpdateFlags::SceneGraphChanged;
    const bool lightChanged = any(mLaserPosition != mLaserPrevPosition) || any(mLaserDirection != mLaserPrevDirection) ||
        any(mLaserPower != mPreviousLaserPower) || mLaserCosAngle != mPreviousLaserCosAngle;
    if (mTemporalHistoryValid && ((updates & ~allowedUpdates) != IScene::UpdateFlags::None ||
        (!mOptions.restir.isSceneDynamic && lightChanged) || mpScene->getCamera()->getApertureRadius() > 0.f))
        mTemporalHistoryValid = false;

    if (!mpEmissiveSampler && (mOptions.sampling.samplingMethod != TimeGatedSamplingMethod::DIRECT))
    {
        const auto& pLights = mpScene->getITriCollection(pRenderContext);
        FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
        FALCOR_ASSERT(!mpEmissiveSampler);

        mLightBVHOptions.buildOptions.maxTriangleCountPerLeaf = 1;
        
        switch (mOptions.sampling.triSampler)
        {
        case EmissiveLightSamplerType::Uniform:
            mpEmissiveSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, mpScene->getITriCollection(pRenderContext));
            break;
        case EmissiveLightSamplerType::LightBVH:
            mpEmissiveSampler = std::make_unique<LightBVHSampler>(pRenderContext, mpScene->getITriCollection(pRenderContext), mLightBVHOptions);
            break;
        case EmissiveLightSamplerType::Power:
            mpEmissiveSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, mpScene->getITriCollection(pRenderContext));
            break;
        default:
            FALCOR_THROW("Unknown emissive light sampler type");
        }
        mpEmissiveSampler->update(pRenderContext, mpScene->getITriCollection(pRenderContext));
    }
    
    if(!mpComputePass){
        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getShaderDefines(renderData));
        
        if(mpEmissiveSampler)
            defines.add(mpEmissiveSampler->getDefines());

        mpComputePass = ComputePass::create(mpDevice, desc, defines, true);

        // Bind static resources
        ShaderVar var = mpComputePass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
    }

    if(!mpSpatialReusePass){
        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSpatialReuseFile).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getShaderDefines(renderData));

        if(mpEmissiveSampler)
            defines.add(mpEmissiveSampler->getDefines());

        defines.add("NEIGHBOR_OFFSET_COUNT", std::to_string(kNeighborOffsetCount));

        mpSpatialReusePass = ComputePass::create(mpDevice, desc, defines, true);

        // Bind static resources
        ShaderVar var = mpSpatialReusePass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
    }

    prepareResources(pRenderContext, renderData);

    if (is_set(mpScene->getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(mpScene->getUpdates(), IScene::UpdateFlags::GeometryChanged))
    {
        FALCOR_THROW("This render pass does not support scene changes that require shader recompilation.");
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    if(mpEmissiveSampler)
    {
        mpScene->getTriCollection(pRenderContext);
    }

    // Configure depth-of-field.
    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr)
    {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    // Specialize program.
    mpComputePass->getProgram()->addDefines(getShaderDefines(renderData));
    
    // update time
    mTcurr = float((float(mTimeGateFrameCount % mOptions.timeGate.timeBin) / mOptions.timeGate.timeBin) * (mOptions.timeGate.timeMax - mOptions.timeGate.timeMin) + mOptions.timeGate.timeMin);
    // mTprev = float((float(mPrevTimeGateFrameCount % mOptions.timeGate.timeBin) / mOptions.timeGate.timeBin) * (mOptions.timeGate.timeMax - mOptions.timeGate.timeMin) + mOptions.timeGate.timeMin);
    
    // bind variables
    auto var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    // Spawn the rays.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpComputePass->execute(pRenderContext, uint3(targetDim, 1));
    
    // swap reservoirs
    // std::swap(mpCurrReservoirs, mpPrevReservoirs);
    spatialReuse(pRenderContext, renderData);

    mFrameCount++;

    // swap reservoirs
    std::swap(mpCurrReservoirs, mpPrevReservoirs);

    // copy v buffer
    mTemporalHistoryValid = mOptions.restir.useTemporalReuse &&
        mpScene->getCamera()->getApertureRadius() == 0.f;
    if (mTemporalHistoryValid)
        pRenderContext->copyResource(mpTemporalVBuffer.get(), renderData["vbuffer"].get());
    mPreviousCameraPosition = mpScene->getCamera()->getPosition();
    mPreviousLaserPower = mLaserPower;
    mPreviousLaserCosAngle = mLaserCosAngle;

    mLaserPrevDirection = mLaserDirection;
    mLaserPrevPosition = mLaserPosition;
    mPrevTimeGateFrameCount = mTimeGateFrameCount;
    mTprev = mTcurr;

    // Temporal reuse maps the history from tprev to the new gate, so it stays valid.
    if (mOptions.timeGate.shiftGate && mOptions.timeGate.timeMax > mOptions.timeGate.timeMin)
    {
        incrementTimeGateFrame();
        mGateMoved = true;
    }
}

void TimeGatedReSTIRInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    // Settings validated together; a rejected edit restores them.
    const auto previousSamplingMethod = mOptions.sampling.samplingMethod;
    const auto previousTriSampler = mOptions.sampling.triSampler;
    const uint previousMaxBounces = mOptions.pathTracing.maxBounces;
    const bool previousSceneDynamic = mOptions.restir.isSceneDynamic;

    if (auto group = widget.group("Time gate", true))
    {
        dirty |= mOptions.timeGate.renderUI(group, mTcurr,
            " Temporal reuse maps the history to each new gate.");
    }

    if (auto group = widget.group("Initial sampling", true))
    {
        dirty |= mOptions.pathTracing.renderSamplingUI(group, " The primary hit is not connected to the laser spot.");
        // Ellipsoidal initial sampling supports the Uniform and LightBVH triangle samplers only.
        dirty |= mOptions.sampling.renderUI(group, false);

        if (mOptions.sampling.samplingMethod == TimeGatedSamplingMethod::DIRECT)
        {
            dirty |= group.var("Wide gate window", mOptions.restir.timeGateWindowRough, 0.f, 1000.0f);
            group.tooltip("Direct sampling with a Box or Tent gate only: when wider than Gate window, a fraction of "
                          "the paths is traced with this wider gate and shrunk into the gate by the path-length "
                          "shift. 0 disables it.", true);
            dirty |= group.var("Wide gate path fraction", mOptions.restir.roughTimeGateSampleRatio, 0.f, 1.f);
            group.tooltip("Fraction of the paths per pixel traced with the wide gate.", true);
        }
    }

    if (auto group = widget.group("Reuse", true))
    {
        dirty |= group.var("Spatial iterations", mOptions.restir.spatialReuseIteration, 0u, 16u);
        group.tooltip("Spatial reuse passes per frame. 0 disables spatial reuse.", true);

        dirty |= group.var("Spatial neighbors", mOptions.restir.spatialReuseNeighborCount, 1u, 64u);
        group.tooltip("Neighbor pixels resampled in each spatial pass.", true);

        dirty |= group.var("Spatial radius (px)", mOptions.restir.spatialReuseGatherRadius, 1.f, 128.f);
        group.tooltip("Radius, in pixels, within which spatial neighbors are chosen.", true);

        dirty |= group.checkbox("Temporal reuse", mOptions.restir.useTemporalReuse);
        group.tooltip("Resample the previous frame's reservoir (reprojected with motion vectors when the mvec "
                      "input is connected), shifting its paths from the previous gate to the current one.", true);

        if (mOptions.restir.useTemporalReuse)
        {
            dirty |= group.var("History length (frames)", mOptions.restir.temporalHistoryLength, -1.f, 100000.f);
            group.tooltip("Cap on the history's sample count, in frames of samples per pixel. 0 ignores the "
                          "history; a negative value leaves it uncapped.", true);
        }

        dirty |= group.checkbox("Dynamic light", mOptions.restir.isSceneDynamic);
        group.tooltip("Keep the temporal history when the laser moves or changes, re-evaluating the lighting of "
                      "reused paths. Off: any laser change discards the history. Geometry changes always discard "
                      "it.", true);
    }

    if (auto group = widget.group("Shift mapping", true))
    {
        static const Gui::DropdownList kShiftmapMethodList = {
            {(uint32_t)ShiftmapMethod::NO, "None (naive reuse)"},
            {(uint32_t)ShiftmapMethod::LOCAL_TANGENT_SURFACE, "Local tangent"},
            {(uint32_t)ShiftmapMethod::BARYCENTRIC, "Barycentric"},
            {(uint32_t)ShiftmapMethod::RAY_TRACE_HEMISPHERE, "Ray trace"},
            {(uint32_t)ShiftmapMethod::AREA_ADAPTIVE, "Area adaptive"},
            {(uint32_t)ShiftmapMethod::RAY_TRACE_CHART, "Ray trace chart"},
        };
        uint32_t shiftmapMethod = (uint32_t)mOptions.restir.shiftmapMethod;
        if (group.dropdown("Method", kShiftmapMethodList, shiftmapMethod))
        {
            mOptions.restir.shiftmapMethod = (ShiftmapMethod)shiftmapMethod;
            dirty = true;
        }
        group.tooltip("How a reused path is fitted to the target pixel's gate. The reconnection vertex is moved so "
                      "the path length changes by the gate difference, using a Newton solve on the chosen chart.\n"
                      "None keeps the vertex fixed (naive reuse).", true);

        dirty |= group.var("Reconnection roughness threshold", mOptions.restir.reconnectionRoughnessThreshold, 0.f, 1.f);
        group.tooltip("A path can reconnect at a segment only if both of its vertices are rougher than this.", true);

        if (mOptions.restir.shiftmapMethod != ShiftmapMethod::NO)
        {
            static const Gui::DropdownList kGaugeModeList = {
                {(uint32_t)GaugeMode::CONSTANT, "Constant axis"},
                {(uint32_t)GaugeMode::ORTHO_GRAD_START, "Orthogonal to start gradient"},
                {(uint32_t)GaugeMode::ORTHO_AVG_GRAD, "Orthogonal to average gradient"},
            };
            uint32_t gaugeMode = (uint32_t)mOptions.restir.gaugeMode;
            if (group.dropdown("Gauge", kGaugeModeList, gaugeMode))
            {
                mOptions.restir.gaugeMode = (GaugeMode)gaugeMode;
                dirty = true;
            }
            group.tooltip("Fixes the direction left free by the one path-length constraint in the 2D Newton solve.", true);

            if (mOptions.restir.gaugeMode == GaugeMode::CONSTANT)
            {
                dirty |= group.var("Gauge axis", mOptions.restir.gaugeAxis, -1.f, 1.f);
                group.tooltip("Chart-space axis of the constant gauge. (0, 0) picks a random axis per shift.", true);
            }

            dirty |= group.var("Newton iterations", mOptions.restir.newtonMaxIteration, 1u, 64u);
            group.tooltip("Maximum Newton iterations per shift.", true);
        }
    }

    if (auto group = widget.group("Light", true))
        dirty |= mOptions.pathTracing.renderLightUI(group);

    if (auto group = widget.group("Output", true))
        dirty |= mOptions.pathTracing.renderOutputUI(group, false);

    if (dirty)
    {
        mUIWarning.clear();
        // Same constraint as parseProperties(): see the comment there.
        if (mOptions.restir.isSceneDynamic && mOptions.sampling.samplingMethod != TimeGatedSamplingMethod::DIRECT && mOptions.pathTracing.maxBounces > 3)
        {
            mUIWarning = "Ellipsoidal sampling with a dynamic light supports at most 3 bounces.";
            mOptions.sampling.samplingMethod = previousSamplingMethod;
            mOptions.pathTracing.maxBounces = previousMaxBounces;
            mOptions.restir.isSceneDynamic = previousSceneDynamic;
        }
        // Rebuild the sampler and programs: the emissive sampler's defines are only added when they are created.
        if (mOptions.sampling.triSampler != previousTriSampler)
            mpEmissiveSampler.reset();
        if (mOptions.sampling.samplingMethod != previousSamplingMethod || mOptions.sampling.triSampler != previousTriSampler)
        {
            mpComputePass = nullptr;
            mpSpatialReusePass = nullptr;
        }
        // Pass the flag to downstream passes (accumulation reset) and discard the ReSTIR history.
        mOptionsChanged = true;
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void TimeGatedReSTIRInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;
    mTemporalHistoryValid = false;
    mpReflectTypes = nullptr;

    // Set new scene.
    mpScene = pScene;
}

void TimeGatedReSTIRInline::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    defines.add("IS_SCENE_DYNAMIC", mOptions.restir.isSceneDynamic ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.pathTracing.isLightSourceLaser ? "1" : "0");
    
    // create helper program
    if (!mpReflectTypes)
    {
        auto globalTypeConformances = mpScene->getTypeConformances();

        // Create ReSTIR passes.
        ProgramDesc baseDesc;
        baseDesc.addShaderModules(mpScene->getShaderModules());
        baseDesc.addTypeConformances(globalTypeConformances);
        baseDesc.addShaderLibrary(kReflectTypesFile).csEntry("main");

        // DefineList defines;
        mpReflectTypes = ComputePass::create(mpDevice, baseDesc, defines, false);
    }

    auto preparePass = [&](ref<ComputePass> pass)
    {
        // Note that we must use set instead of add defines to replace any stale state.
        pass->getProgram()->setDefines(defines);
        
        // Recreate program vars. This may trigger recompilation if needed.
        // Note that program versions are cached, so switching to a previously used specialization is faster.
        pass->setVars(nullptr);
    };
    preparePass(mpReflectTypes);

    FALCOR_ASSERT(mpScene);
    auto var = mpReflectTypes->getRootVar();
    const uint2 targetDim = renderData.getDefaultTextureDims();
    const uint32_t screenPixelCount = targetDim.x * targetDim.y;

    if (any(mTemporalHistoryDimensions != targetDim)) mTemporalHistoryValid = false;

    // create reservoirs
    if(!mpPrevReservoirs || (mpPrevReservoirs->getElementCount() != screenPixelCount)){
        mpPrevReservoirs = mpDevice->createStructuredBuffer(
            var["reservoirs"],
            screenPixelCount,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            MemoryType::DeviceLocal,
            nullptr,
            false
        );
    }
    if(!mpCurrReservoirs|| (mpCurrReservoirs->getElementCount() != screenPixelCount)){
        mpCurrReservoirs = mpDevice->createStructuredBuffer(
            var["reservoirs"],
            screenPixelCount,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            MemoryType::DeviceLocal,
            nullptr,
            false
        );
    }

    // create neighbor offset bufferes (used for spatial reuse)
    if(!mpNeighborOffsets){
        mpNeighborOffsets = createNeighborOffsetTexture(kNeighborOffsetCount);
    }
    
    if (mOptions.restir.useTemporalReuse &&
        (!mpTemporalVBuffer || any(mTemporalHistoryDimensions != targetDim) ||
         mpTemporalVBuffer->getFormat() != renderData.getTexture("vbuffer")->getFormat()))
    {
        mpTemporalVBuffer = mpDevice->createTexture2D(
            targetDim.x, targetDim.y, renderData.getTexture("vbuffer")->getFormat(), 1, 1);
        mTemporalHistoryDimensions = targetDim;
        mTemporalHistoryValid = false;
    }

}

ref<Texture> TimeGatedReSTIRInline::createNeighborOffsetTexture(uint32_t sampleCount)
{
    std::unique_ptr<int8_t[]> offsets(new int8_t[sampleCount * 2]);
    const int R = 254;
    const float phi2 = 1.f / 1.3247179572447f;
    float u = 0.5f;
    float v = 0.5f;
    for (uint32_t index = 0; index < sampleCount * 2;)
    {
        u += phi2;
        v += phi2 * phi2;
        if (u >= 1.f) u -= 1.f;
        if (v >= 1.f) v -= 1.f;

        float rSq = (u - 0.5f) * (u - 0.5f) + (v - 0.5f) * (v - 0.5f);
        if (rSq > 0.25f) continue;

        offsets[index++] = int8_t((u - 0.5f) * R);
        offsets[index++] = int8_t((v - 0.5f) * R);
    }
    return mpDevice->createTexture1D(
        sampleCount, ResourceFormat::RG8Snorm, 1, 1, offsets.get());
}
