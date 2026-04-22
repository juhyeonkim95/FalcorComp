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
#include "MinimalTimeGatedReSTIR.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, MinimalTimeGatedReSTIR>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/MinimalTimeGatedReSTIR/MinimalTimeGatedReSTIR.cs.slang";
const char kReflectTypesFile[] = "RenderPasses/MinimalTimeGatedReSTIR/ReflectTypes.cs.slang";
const char kSpatialReuseFile[] = "RenderPasses/MinimalTimeGatedReSTIR/SpatialReuse.cs.slang";
const char kSEvaluateFinalSamplesFile[] = "RenderPasses/MinimalTimeGatedReSTIR/EvaluateFinalSamples.cs.slang";
const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
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

const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kSamplesPerPixel[] = "samplesPerPixel";
const char kTimeGateWindow[] = "timeGateWindow";
const char kTimeGateWindowRough[] = "timeGateWindowRough";
const char kTimeGateMode[] = "timeGateMode";
const char kTimeMin[] = "timeMin";
const char kTimeMax[] = "timeMax";
const char kTimeBin[] = "timeBin";
const char kSamplingMethod[] = "samplingMethod";
const char kEmissiveSampler[] = "emissiveSampler";
const char kLaserHitVBufferRes[] = "laserHitVBufferRes";
const char kShiftmapMethod[] = "shiftmapMethod";
const char kGaugeAxis[] = "gaugeAxis";
const char kGaugeMode[] = "gaugeMode";
const char kSpatialReusePassIteration[] = "spatialReuseIteration";
const char kSpatialReuseNeighborCount[] = "spatialReuseNeighborCount";
const char kSpatialReuseGatherRadius[] = "spatialReuseGatherRadius";
const char kSpecularRoughnessThreshold[] = "specularRoughnessThreshold";

const uint32_t kNeighborOffsetCount = 8192;
} // namespace

MinimalTimeGatedReSTIR::MinimalTimeGatedReSTIR(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void MinimalTimeGatedReSTIR::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxBounces)
            mMaxBounces = value;
        else if (key == kComputeDirect)
            mComputeDirect = value;
        else if (key == kUseImportanceSampling)
            mUseImportanceSampling = value;
        else if (key == kSamplesPerPixel)
            mSamplesPerPixel = value;
        else if (key == kTimeGateMode)
            mTimeGateMode = TimeGateModeTable[value];
        else if (key == kTimeGateWindow)
            mTimeGateWindow = value;
        else if (key == kTimeGateWindowRough)
            mTimeGateWindowRough = value;
        else if (key == kTimeMin)
            mTimeMin = value;
        else if (key == kTimeMax)
            mTimeMax = value;
        else if (key == kTimeBin)
            mTimeBin = value;
        else if (key == kSamplingMethod)
            mSamplingMethod = SamplingMethodTable[value];
        else if (key == kEmissiveSampler)
            mTriSampler = value;
        else if (key == kLaserHitVBufferRes)
            mLaserHitVBufferRes = value;
        else if (key == kShiftmapMethod)
            mShiftmapMethod = ShiftmapMethodTable[value];
        else if (key == kGaugeAxis)
            mGaugeAxis = value;
        else if (key == kGaugeMode)
            mGaugeMode = GaugeModeTable[value];
        else if (key == kSpatialReuseGatherRadius)
            mSpatialReuseGatherRadius = value;
        else if(key == kSpatialReusePassIteration)
            mSpatialReusePassIteration = value;
        else if(key == kSpatialReuseNeighborCount)
            mSpatialReuseNeighborCount = value;
        else if(key == kSpecularRoughnessThreshold)
            mSpecularRoughnessThreshold = value;
        else
            logWarning("Unknown property '{}' in MinimalTimeGatedReSTIR properties.", key);
    }
}

Properties MinimalTimeGatedReSTIR::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    return props;
}

RenderPassReflection MinimalTimeGatedReSTIR::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassInputs(reflector, kLaserHitInputChannels, ResourceBindFlags::ShaderResource, mLaserHitVBufferRes);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

DefineList MinimalTimeGatedReSTIR::getShaderDefines(const RenderData& renderData) const{
    DefineList defines;

    defines.add("MAX_BOUNCES", std::to_string(mMaxBounces));
    defines.add("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mSamplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::DIRECT));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL));
    defines.add("TRIANGLE_APPROX", std::to_string((uint32_t)TimeGatedSamplingMethod::TRIANGLE_APPROX));
    defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)mShiftmapMethod));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserHitInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    return defines;
}

void MinimalTimeGatedReSTIR::bindShaderData(const ShaderVar& var, const RenderData& renderData)
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
    var["CB"]["gFrameDim"] = targetDim;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["gLaserHitVBufferRes" ] = mLaserHitVBufferRes;
    var["CB"]["specularRoughnessThreshold" ] = mSpecularRoughnessThreshold;
    
    // transients
    var["Laser_CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
    var["Laser_CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    var["Laser_CB"]["laserPower"] = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    var["Laser_CB"]["laserCosAngle"] = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;
    
    var["CB"]["samplesPerPixel"] = mSamplesPerPixel;

    var["TimeGate"]["time_gate_window"] = mTimeGateWindow;
    var["TimeGate"]["time_gate_window_rough"] = mTimeGateWindowRough;
    var["TimeGate"]["time_gate_mode"] = uint(mTimeGateMode);

    // if(mFrameCount == mTimeBin){
    //     mFrameCount = 0;
    // }
    var["TimeGate"]["tcurr"] = mTcurr;
    var["TimeGate"]["tprev"] = mTprev;

    var["Shiftmap_CB"]["gGaugeAxis"] = mGaugeAxis;
    var["Shiftmap_CB"]["gGaugeMode"] = uint(mGaugeMode);
    var["Shiftmap_CB"]["gShiftMappingMethod"] = uint(mShiftmapMethod);

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
}

void MinimalTimeGatedReSTIR::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
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
    var["neighborCount"] = mSpatialReuseNeighborCount;
    var["gatherRadius"] = mSpatialReuseGatherRadius;
    
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

    rootvar["TimeGate"]["time_gate_window"] = mTimeGateWindow;
    rootvar["TimeGate"]["time_gate_window_rough"] = mTimeGateWindowRough;
    rootvar["TimeGate"]["time_gate_mode"] = uint(mTimeGateMode);
    rootvar["TimeGate"]["tcurr"] = mTcurr;
    rootvar["TimeGate"]["tprev"] = mTprev;

    rootvar["Laser_CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
    rootvar["Laser_CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    rootvar["Laser_CB"]["laserPower"] = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    rootvar["Laser_CB"]["laserCosAngle"] = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;
    
    rootvar["Shiftmap_CB"]["gGaugeAxis"] = mGaugeAxis;
    rootvar["Shiftmap_CB"]["gGaugeMode"] = uint(mGaugeMode);
    rootvar["Shiftmap_CB"]["gShiftMappingMethod"] = uint(mShiftmapMethod);

    for(uint iteration=0; iteration < mSpatialReusePassIteration; iteration++){
        std::swap(mpCurrReservoirs, mpPrevReservoirs);
        var["gRandomSeed"] = mRandomSeed++;
        var["prevReservoirs"] = mpPrevReservoirs;
        var["currReservoirs"] = mpCurrReservoirs;
        mpSpatialReusePass->execute(pRenderContext, {targetDim.x, targetDim.y, 1});
    }
}

void MinimalTimeGatedReSTIR::finalEvaluate(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto rootvar = mpFinalEvaluatePass->getRootVar();
    auto var = rootvar["CB"]["gEvaluateFinalSamples"];

    const uint2 targetDim = renderData.getDefaultTextureDims();
    var["gFrameDim"] = targetDim;
    var["currReservoirs"] = mpCurrReservoirs;

    rootvar["TimeGate"]["time_gate_window"] = mTimeGateWindow;
    rootvar["TimeGate"]["time_gate_window_rough"] = mTimeGateWindowRough;
    rootvar["TimeGate"]["time_gate_mode"] = uint(mTimeGateMode);
    rootvar["TimeGate"]["tcurr"] = mTcurr;
    rootvar["TimeGate"]["tprev"] = mTprev;

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

void MinimalTimeGatedReSTIR::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
        for (auto it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    if (!mpEmissiveSampler && (mSamplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL))
    {
        const auto& pLights = mpScene->getITriCollection(pRenderContext);
        FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
        FALCOR_ASSERT(!mpEmissiveSampler);

        switch (mTriSampler)
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
    
    uint m = mFrameCount % mTimeBin;
    mTcurr = float((float(m) / mTimeBin) * (mTimeMax - mTimeMin) + mTimeMin);
    mTprev = float((float((m == 0 ? 0: m - 1) ) / mTimeBin) * (mTimeMax - mTimeMin) + mTimeMin);

    // bind variables
    auto var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    // Spawn the rays.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpComputePass->execute(pRenderContext, uint3(targetDim, 1));
    

    // swap reservoirs
    // std::swap(mpCurrReservoirs, mpPrevReservoirs);
    // spatialReuse(pRenderContext, renderData);
    // finalEvaluate(pRenderContext, renderData);

    mFrameCount++;

    // swap reservoirs
    std::swap(mpCurrReservoirs, mpPrevReservoirs);
}

void MinimalTimeGatedReSTIR::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.var("Time Gate Window", mTimeGateWindow, 0.001f, 1.0f);
    widget.tooltip("Time gate window for transient rendering", true);

    dirty |= widget.var("Time Min", mTimeMin, 2.0f, 20.0f);
    widget.tooltip("Minimum time in unit of distance", true);
    
    dirty |= widget.var("Time Max", mTimeMax, 6.0f, 20.0f);
    widget.tooltip("Maximum time in unit of distance", true);

    dirty |= widget.var("Samples per pixel", mSamplesPerPixel, 1u, 1024u);
    widget.tooltip("Samples per pixel", true);

    dirty |= widget.var("Max bounces", mMaxBounces, 0u, 1u << 16);
    widget.tooltip("Maximum path length for indirect illumination.\n0 = direct only\n1 = one indirect bounce etc.", true);

    dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    widget.tooltip("Compute direct illumination.\nIf disabled only indirect is computed (when max bounces > 0).", true);

    dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);
    widget.tooltip("Use importance sampling for materials", true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}

void MinimalTimeGatedReSTIR::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;
    mpReflectTypes = nullptr;

    // Set new scene.
    mpScene = pScene;
}

void MinimalTimeGatedReSTIR::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());

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

    // printf("_____________________Struct size: %d\n", mpPrevReservoirs->getStructSize());
    
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

    if(!mpLocks|| (mpLocks->getElementCount() != screenPixelCount)){
        mpLocks = mpDevice->createBuffer(
            sizeof(uint32_t) * screenPixelCount,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            MemoryType::DeviceLocal,
            nullptr
        );
    }

    if(!mpNeighborOffsets){
        mpNeighborOffsets = createNeighborOffsetTexture(kNeighborOffsetCount);
    }
}

ref<Texture> MinimalTimeGatedReSTIR::createNeighborOffsetTexture(uint32_t sampleCount)
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