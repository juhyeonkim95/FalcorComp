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
#include "TransientHistogramReSTIRInline.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regTransientHistogramReSTIRInline(pybind11::module& m)
{
    pybind11::class_<TransientHistogramReSTIRInline, RenderPass, ref<TransientHistogramReSTIRInline>> pass(m, "TransientHistogramReSTIRInline");
    // pass.def_property("m", &MinimalTimeGatedPathTracer::isEnabled, &MinimalTimeGatedPathTracer::setEnabled);
    pass.def("reset_histogram", &TransientHistogramReSTIRInline::resetHistogram);
}


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TransientHistogramReSTIRInline>();
    ScriptBindings::registerBinding(regTransientHistogramReSTIRInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TransientHistogramReSTIRInline/InitialSampleGeneration.cs.slang";
const char kReflectTypesFile[] = "RenderPasses/TransientHistogramReSTIRInline/ReflectTypes.cs.slang";
const char kSpatialReuseFile[] = "RenderPasses/TransientHistogramReSTIRInline/SpatialReuse.cs.slang";
const char kSEvaluateFinalSamplesFile[] = "RenderPasses/TransientHistogramReSTIRInline/EvaluateFinalSamples.cs.slang";
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

const ChannelList kHistogramOutputChannelsRGB = {
    // clang-format off
    { "histogram",          "gTransientHistogram", "Output color", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const ChannelList kHistogramOutputChannelSingle = {
    // clang-format off
    { "histogram",          "gTransientHistogram", "Output color", false, ResourceFormat::R32Float },
    // clang-format on
};

const char kUseBinReuse[] = "useBinReuse";
const char kRandomSeed[] = "randomSeed";
const uint32_t kNeighborOffsetCount = 8192;
} // namespace

TransientHistogramReSTIRInline::TransientHistogramReSTIRInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void TransientHistogramReSTIRInline::resetHistogram()
{
    mNeedToClearHistogram = true;
}

// void TransientHistogramReSTIRInline::incrementTimeGateFrame()
// {
//     mTimeGateFrameCount += 1;
// }

void TransientHistogramReSTIRInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.histogram.parse(key, value) || mOptions.pathTracing.parse(key, value) ||
            mOptions.restir.parse(key, value))
            continue;
        if (key == kUseBinReuse)
            mOptions.useBinReuse = value;
        else if (key == kRandomSeed)
            mRandomSeed = value;
        else
            logWarning("Unknown property '{}' in TransientHistogramReSTIRInline properties.", key);
    }
}

Properties TransientHistogramReSTIRInline::getProperties() const
{
    Properties props;
    mOptions.histogram.serialize(props);
    mOptions.pathTracing.serialize(props);
    mOptions.restir.serialize(props);
    props[kUseBinReuse] = mOptions.useBinReuse;
    props[kRandomSeed] = mRandomSeed;
    return props;
}

RenderPassReflection TransientHistogramReSTIRInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassInputs(reflector, kLaserHitInputChannels, ResourceBindFlags::ShaderResource, mOptions.restir.laserHitVBufferRes);
    addRenderPassOutputs(reflector, kOutputChannels);

    ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;

    for (const auto& it : kHistogramOutputChannels)
    {
        auto& tex = reflector.addOutput(it.name, it.desc).texture3D(0, 0, mOptions.histogram.timeBin);
        tex.bindFlags(ResourceBindFlags::UnorderedAccess);
        if (it.format != ResourceFormat::Unknown)
            tex.format(it.format);
        if (it.optional)
            tex.flags(RenderPassReflection::Field::Flags::Optional);
    }

    return reflector;
}

DefineList TransientHistogramReSTIRInline::getShaderDefines(const RenderData& renderData) const{
    DefineList defines;

    defines.add("MAX_BOUNCES", std::to_string(mOptions.pathTracing.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.pathTracing.computeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("RESERVOIR_SCALAR_TARGET", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.pathTracing.isLightSourceLaser ? "1" : "0");
    
    defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)mOptions.restir.shiftmapMethod));
    defines.add("USE_TEMPORAL_REUSE", mOptions.restir.useTemporalReuse ? "1" : "0");

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserHitInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    defines.add(getValidResourceDefines(kHistogramOutputChannels, renderData));
    
    return defines;
}

void TransientHistogramReSTIRInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();

    // Direct initial sampling uses only LaserLightSampler.

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
    // printf("1: %.4f, %.4f, %.4f\n", mLaserPosition.x, mLaserPosition.y, mLaserPosition.z);
    
    
    var["Laser_CB"]["laserPower"] = mLaserPower;
    var["Laser_CB"]["laserCosAngle"] = mLaserCosAngle;
    
    var["CB"]["samplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gTemporalHistoryLength"] = mOptions.restir.temporalHistoryLength;
    if (mOptions.restir.useTemporalReuse)
    {
        // Temporal reuse shifts last frame's paths in this pass.
        var["gTemporalVBuffer"] = mpTemporalVBuffer;
        var["CB"]["gTemporalHistoryValid"] = mTemporalHistoryValid;
        var["CB"]["gPreviousCameraPosition"] = mPreviousCameraPosition;
        var["Shiftmap_CB"]["gGaugeAxis"] = mOptions.restir.gaugeAxis;
        var["Shiftmap_CB"]["gGaugeMode"] = uint(mOptions.restir.gaugeMode);
        var["Shiftmap_CB"]["gShiftMappingMethod"] = uint(mOptions.restir.shiftmapMethod);
        var["Shiftmap_CB"]["gNewtonMaxIteration"] = mOptions.restir.newtonMaxIteration;
        var["Shiftmap_CB"]["gNewtonRelativeTolerance"] = mOptions.restir.newtonRelativeTolerance;
        if (mpEmissiveSampler)
            mpEmissiveSampler->bindShaderData(var["Shiftmap_CB"]["emissiveSamplerShiftmap"]);
    }

    var["TimeGate"]["time_gate_window"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;
    var["TimeGate"]["time_gate_window_rough"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;
    var["TimeGate"]["time_gate_mode"] = uint(mOptions.histogram.filter);

    // if(mFrameCount == mOptions.histogram.timeBin){
    //     mFrameCount = 0;
    // }

    // var["TimeGate"]["tcurr"] = mTcurr;
    var["TimeGate"]["tbin"] = mOptions.histogram.timeBin;
    var["TimeGate"]["tmax"] = mOptions.histogram.timeMax;
    var["TimeGate"]["tmin"] = mOptions.histogram.timeMin;
    var["TimeGate"]["tunit"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;


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

    ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    for (auto channel : kHistogramOutputChannels)
        bind(channel);

}

void TransientHistogramReSTIRInline::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
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
    var["specularRoughnessThreshold"] = mOptions.restir.reconnectionRoughnessThreshold;
    var["gFrameDim"] = targetDim;
    var["neighborOffsets"] = mpNeighborOffsets;
    var["neighborCount"] = mOptions.restir.spatialReuseNeighborCount;
    var["gatherRadius"] = mOptions.restir.spatialReuseGatherRadius;
    var["useBinReuse"] = mOptions.useBinReuse;
    
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
    
    // The histogram is a pass-level global, outside the shared SpatialReuse struct.
    ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    for (auto channel : kHistogramOutputChannels)
        rootvar[channel.texname] = renderData.getTexture(channel.name);

    rootvar["TimeGate"]["time_gate_window"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;
    rootvar["TimeGate"]["time_gate_window_rough"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;
    rootvar["TimeGate"]["time_gate_mode"] = uint(mOptions.histogram.filter);

    rootvar["TimeGate"]["tbin"] = mOptions.histogram.timeBin;
    rootvar["TimeGate"]["tmax"] = mOptions.histogram.timeMax;
    rootvar["TimeGate"]["tmin"] = mOptions.histogram.timeMin;
    rootvar["TimeGate"]["tunit"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;

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

    for(uint iteration=0; iteration < mOptions.restir.spatialReuseIteration; iteration++){
        std::swap(mpCurrReservoirs, mpPrevReservoirs);
        var["gRandomSeed"] = mRandomSeed++;
        var["prevReservoirs"] = mpPrevReservoirs;
        var["currReservoirs"] = mpCurrReservoirs;
        mpSpatialReusePass->execute(pRenderContext, {targetDim.x, targetDim.y, 1});
    }
}

void TransientHistogramReSTIRInline::finalEvaluate(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto rootvar = mpFinalEvaluatePass->getRootVar();
    auto var = rootvar["CB"]["gEvaluateFinalSamples"];

    const uint2 targetDim = renderData.getDefaultTextureDims();
    var["gFrameDim"] = targetDim;
    var["currReservoirs"] = mpCurrReservoirs;

    rootvar["TimeGate"]["time_gate_window"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;
    rootvar["TimeGate"]["time_gate_window_rough"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;
    rootvar["TimeGate"]["time_gate_mode"] = uint(mOptions.histogram.filter);
    rootvar["TimeGate"]["tcurr"] = mTcurr;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kOutputChannels)
        bind(channel);

    mpFinalEvaluatePass->execute(pRenderContext, {targetDim.x, targetDim.y, 1});
}

void TransientHistogramReSTIRInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

        ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
        for (auto it : kHistogramOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    // clear histogram
    if(mNeedToClearHistogram){
        ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
        for (auto it : kHistogramOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        mNeedToClearHistogram = false;
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

    // Temporal reuse assumes static geometry and light; only the camera may move.
    const auto cameraUpdates = IScene::UpdateFlags::CameraMoved |
        IScene::UpdateFlags::CameraPropertiesChanged | IScene::UpdateFlags::CameraSwitched;
    const bool lightChanged = any(mLaserPosition != mPreviousLaserPosition) ||
        any(mLaserDirection != mPreviousLaserDirection) || any(mLaserPower != mPreviousLaserPower) ||
        mLaserCosAngle != mPreviousLaserCosAngle;
    if ((mpScene->getUpdates() & ~cameraUpdates) != IScene::UpdateFlags::None || lightChanged ||
        mpScene->getCamera()->getApertureRadius() > 0.f)
        mTemporalHistoryValid = false;

    
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

    // if(!mpFinalEvaluatePass){
    //     // Create ray tracing program.
    //     ProgramDesc desc;
    //     desc.addShaderModules(mpScene->getShaderModules());
    //     desc.addShaderLibrary(kSEvaluateFinalSamplesFile).csEntry("main");
    //     desc.addTypeConformances(mpScene->getTypeConformances());

    //     DefineList defines;
    //     defines.add(mpScene->getSceneDefines());
    //     defines.add(mpSampleGenerator->getDefines());
    //     defines.add(getShaderDefines(renderData));

    //     mpFinalEvaluatePass = ComputePass::create(mpDevice, desc, defines, true);

    //     ShaderVar var = mpFinalEvaluatePass->getRootVar();
    // }

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
    // mTcurr = float((float(mTimeGateFrameCount % mOptions.histogram.timeBin) / mOptions.histogram.timeBin) * (mOptions.histogram.timeMax - mOptions.histogram.timeMin) + mOptions.histogram.timeMin);
    
    // bind variables
    auto var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    // Spawn the rays.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpComputePass->execute(pRenderContext, uint3(targetDim, 1));
    
    spatialReuse(pRenderContext, renderData);
    // finalEvaluate(pRenderContext, renderData);

    mFrameCount++;

    // The final reservoirs become next frame's temporal history.
    std::swap(mpCurrReservoirs, mpPrevReservoirs);
    mTemporalHistoryValid = mOptions.restir.useTemporalReuse && mpScene->getCamera()->getApertureRadius() == 0.f;
    if (mTemporalHistoryValid)
        pRenderContext->copyResource(mpTemporalVBuffer.get(), renderData["vbuffer"].get());
    mPreviousCameraPosition = mpScene->getCamera()->getPosition();
    mPreviousLaserPosition = mLaserPosition;
    mPreviousLaserDirection = mLaserDirection;
    mPreviousLaserPower = mLaserPower;
    mPreviousLaserCosAngle = mLaserCosAngle;



}

void TransientHistogramReSTIRInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    const uint previousBins = mOptions.histogram.timeBin;
    const bool previousSingleChannel = mOptions.pathTracing.useSingleChannel;

    if (auto group = widget.group("Histogram", true))
        dirty |= mOptions.histogram.renderUI(group, false);

    if (auto group = widget.group("Initial sampling", true))
        dirty |= mOptions.pathTracing.renderSamplingUI(group, " Each vertex is connected to the laser spot.");

    if (auto group = widget.group("Reuse", true))
    {
        dirty |= mOptions.restir.renderReuseUI(group, " Static scene and light; the camera may move.");

        dirty |= group.checkbox("Reuse adjacent bins", mOptions.useBinReuse);
        group.tooltip("Each spatial reuse iteration also resamples bins j-1 and j+1 of the same pixel.", true);
    }

    if (auto group = widget.group("Shift mapping", true))
        dirty |= mOptions.restir.renderShiftMappingUI(group);

    if (auto group = widget.group("Light", true))
        dirty |= mOptions.pathTracing.renderLightUI(group);

    if (auto group = widget.group("Output", true))
        dirty |= mOptions.pathTracing.renderOutputUI(group, true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
        // The histogram texture depends on the bin count and channel count.
        if (mOptions.histogram.timeBin != previousBins || mOptions.pathTracing.useSingleChannel != previousSingleChannel)
            requestRecompile();
    }
}

void TransientHistogramReSTIRInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
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

void TransientHistogramReSTIRInline::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("RESERVOIR_SCALAR_TARGET", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    
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
    const uint32_t screenPixelCount = targetDim.x * targetDim.y * mOptions.histogram.timeBin;

    // create reservoirs (a resize discards the temporal history)
    if(!mpPrevReservoirs || (mpPrevReservoirs->getElementCount() != screenPixelCount)){
        mTemporalHistoryValid = false;
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
    // if(!mpTempReservoirs|| (mpTempReservoirs->getElementCount() != screenPixelCount)){
    //     mpTempReservoirs = mpDevice->createStructuredBuffer(
    //         var["reservoirs"],
    //         screenPixelCount,
    //         ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
    //         MemoryType::DeviceLocal,
    //         nullptr,
    //         false
    //     );
    // }

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

ref<Texture> TransientHistogramReSTIRInline::createNeighborOffsetTexture(uint32_t sampleCount)
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