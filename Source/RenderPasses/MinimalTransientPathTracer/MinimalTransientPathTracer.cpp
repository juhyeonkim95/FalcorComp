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
#include "MinimalTransientPathTracer.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regMinimalTransientPathTracer(pybind11::module& m)
{
    pybind11::class_<MinimalTransientPathTracer, RenderPass, ref<MinimalTransientPathTracer>> pass(m, "MinimalTransientPathTracer");
    // pass.def_property("m", &MinimalTransientPathTracer::isEnabled, &MinimalTransientPathTracer::setEnabled);
    pass.def("reset_histogram", &MinimalTransientPathTracer::resetHistogram);
}


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, MinimalTransientPathTracer>();
    ScriptBindings::registerBinding(regMinimalTransientPathTracer);
}

namespace
{
const char kShaderFile[] = "RenderPasses/MinimalTransientPathTracer/MinimalTransientPathTracer.cs.slang";
const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kLaserInputChannels = {
    // 1 x 1 laser hit buffer
    { "laservbuffer",        "gLaserVBuffer",     "Laser visibility buffer in packed format" },
    { "laserviewW",    "gLaserViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kOutputChannels = {
    // clang-format off
    { "color",          "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const ChannelList kHistogramOutputChannelSingle = {
    // clang-format off
    { "histogram",          "gTransientHistogram", "Output color", false, ResourceFormat::R32Float },
    // clang-format on
};

const ChannelList kHistogramOutputChannelsRGB = {
    // clang-format off
    { "histogram",          "gTransientHistogram", "Output color", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kSamplesPerPixel[] = "samplesPerPixel";
const char kTimeGateWindow[] = "timeGateWindow";
const char kTimeGateMode[] = "timeGateMode";
const char kTimeMin[] = "timeMin";
const char kTimeMax[] = "timeMax";
const char kTimeBin[] = "timeBin";
const char kSamplingMethod[] = "samplingMethod";
const char kEmissiveSampler[] = "emissiveSampler";
const char kSpecularRoughnessThreshold[] = "specularRoughnessThreshold";
const char kDoSampleLaser[] = "doSampleLaser";
const char kLaserCollocated[] = "laserCollocated";
const char kUseAlphaTest[] = "useAlphaTest";
const char kUseEllipsoidalMIS[] = "useEllipsoidalMIS";
const char kUseSingleChannel[] = "useSingleChannel";
const char kIsLightSourceLaser[] = "isLightSourceLaser";
const char kUseKernelDensityEstimation[] = "useKernelDensityEstimation";
} // namespace

MinimalTransientPathTracer::MinimalTransientPathTracer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void MinimalTransientPathTracer::resetHistogram()
{
    mNeedToClearHistogram = true;
}


void MinimalTransientPathTracer::parseProperties(const Properties& props)
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
        else if(key == kSpecularRoughnessThreshold)
            mSpecularRoughnessThreshold = value;
        // else if(key == kDoSampleLaser)
        //     mDoSampleLaser = value;
        else if(key == kLaserCollocated)
            mLaserCollocated = value;
        else if (key == kUseAlphaTest)
            mUseAlphaTest = value;
        else if (key == kUseEllipsoidalMIS)
            mUseEllipsoidalMIS = value;
        else if (key == kUseSingleChannel)
            mUseSingleChannel = value;
        else if (key == kIsLightSourceLaser)
            mIsLightSourceLaser = value;
        else if (key == kUseKernelDensityEstimation)
            mUseKernelDensityEstimation = value;
        else
            logWarning("Unknown property '{}' in MinimalTransientPathTracer properties.", key);
    }
}

Properties MinimalTransientPathTracer::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    return props;
}

RenderPassReflection MinimalTransientPathTracer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassOutputs(reflector, kOutputChannels);

    ChannelList kHistogramOutputChannels = mUseSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;

    for (const auto& it : kHistogramOutputChannels)
    {
        auto& tex = reflector.addOutput(it.name, it.desc).texture3D(0, 0, mTimeBin);
        tex.bindFlags(ResourceBindFlags::UnorderedAccess);
        if (it.format != ResourceFormat::Unknown)
            tex.format(it.format);
        if (it.optional)
            tex.flags(RenderPassReflection::Field::Flags::Optional);
    }

    return reflector;
}

DefineList MinimalTransientPathTracer::getShaderDefines(const RenderData& renderData) const{
    DefineList defines;

    defines.add("MAX_BOUNCES", std::to_string(mMaxBounces));
    defines.add("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mUseAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mUseSingleChannel ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mIsLightSourceLaser ? "1" : "0");
    defines.add("USE_KERNEL_DENSITY_ESTIMATION", mUseKernelDensityEstimation ? "1" : "0");
    
    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mSamplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::DIRECT));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL));
    defines.add("USE_ELLIPSOIDAL_DIRECT_MIS", mUseEllipsoidalMIS ? "1" : "0");
    defines.add("TRIANGLE_APPROX", std::to_string((uint32_t)TimeGatedSamplingMethod::TRIANGLE_APPROX));

    defines.add("HISTOGRAM_FILTER", std::to_string((uint32_t)mTimeGateMode));
    defines.add("HISTOGRAM_FILTER_BOX", std::to_string((uint32_t)TimeGateMode::BOX));
    defines.add("HISTOGRAM_FILTER_TENT", std::to_string((uint32_t)TimeGateMode::TENT));
    

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    ChannelList kHistogramOutputChannels = mUseSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    defines.add(getValidResourceDefines(kHistogramOutputChannels, renderData));

    return defines;
}

void MinimalTransientPathTracer::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();

    if(mpEmissiveSampler){
        mpEmissiveSampler->bindShaderData(var["emissiveSampler"]);
    }

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = targetDim;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["specularRoughnessThreshold" ] = mSpecularRoughnessThreshold;
    
    // transients
    if(mLaserCollocated && mpScene){
        var["CB"]["laserOrigin"] = mpScene->getCamera()->getPosition();
        var["CB"]["laserDirection"] = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    } else {
        var["CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
        var["CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    }
    var["CB"]["laserPower"] = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    var["CB"]["laserCosAngle"] = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;
    
    var["CB"]["samplesPerPixel"] = mSamplesPerPixel;
    // var["CB"]["doSampleLaser"] = mDoSampleLaser;
    
    var["TimeGate"]["time_gate_mode"] = uint(mTimeGateMode);
    
    var["TimeGate"]["tbin"] = mTimeBin;
    var["TimeGate"]["tmax"] = mTimeMax;
    var["TimeGate"]["tmin"] = mTimeMin;
    var["TimeGate"]["tunit"] = (mTimeMax - mTimeMin) / mTimeBin;

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

    ChannelList kHistogramOutputChannels = mUseSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    for (auto channel : kHistogramOutputChannels)
        bind(channel);
}

void MinimalTransientPathTracer::execute(RenderContext* pRenderContext, const RenderData& renderData)
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
        ChannelList kHistogramOutputChannels = mUseSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
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
        ChannelList kHistogramOutputChannels = mUseSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
        for (auto it : kHistogramOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        mNeedToClearHistogram = false;
    }
    

    if (!mpEmissiveSampler && (mSamplingMethod == TimeGatedSamplingMethod::TRIANGLE_APPROX))
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
    
    // bind variables
    auto var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    // Spawn the rays.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpComputePass->execute(pRenderContext, uint3(targetDim, 1));

    mFrameCount++;
    
}

void MinimalTransientPathTracer::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.var("Time Gate Window", mTimeGateWindow, 0.001f, 1000.0f);
    widget.tooltip("Time gate window for transient rendering", true);

    dirty |= widget.var("Time Min", mTimeMin, 0.0f, 1000.0f);
    widget.tooltip("Minimum time in unit of distance", true);
    
    dirty |= widget.var("Time Max", mTimeMax, 6.0f, 1000.0f);
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

void MinimalTransientPathTracer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;

    // Set new scene.
    mpScene = pScene;
}