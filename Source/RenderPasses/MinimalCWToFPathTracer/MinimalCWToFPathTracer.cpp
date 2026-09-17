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
#include "MinimalCWToFPathTracer.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include <fstream>

static void regMinimalCWToFPathTracer(pybind11::module& m)
{
    pybind11::class_<MinimalCWToFPathTracer, RenderPass, ref<MinimalCWToFPathTracer>> pass(m, "MinimalCWToFPathTracer");
    // pass.def_property("m", &MinimalCWToFPathTracer::isEnabled, &MinimalCWToFPathTracer::setEnabled);
    pass.def("increment_time_gate_frame", &MinimalCWToFPathTracer::incrementTimeGateFrame);
    pass.def("set_time_gate_info", &MinimalCWToFPathTracer::setTimeGateInfo);
    pass.def("set_pattern_info", &MinimalCWToFPathTracer::setPatternInfo);
    pass.def("update_laser_info", &MinimalCWToFPathTracer::updateLaserInfo);
}


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, MinimalCWToFPathTracer>();
    ScriptBindings::registerBinding(regMinimalCWToFPathTracer);
}


// ---- helper (local to this file) ----
static std::vector<uint32_t> loadUintArrayFromTxt(const std::string& filename)
{
    std::ifstream file(filename);
    if (!file.is_open())
        throw std::runtime_error("Failed to open file: " + filename);

    std::vector<uint32_t> data;
    std::string line;

    while (std::getline(file, line))
    {
        std::stringstream ss(line);
        uint32_t value;

        while (ss >> value)
            data.push_back(value);
    }

    return data;
}

namespace
{
const char kShaderFile[] = "RenderPasses/MinimalCWToFPathTracer/MinimalCWToFPathTracer.cs.slang";
const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

// const ChannelList kLaserInputChannels = {
//     // 1 x 1 laser hit buffer
//     { "laservbuffer",        "gLaserVBuffer",     "Laser visibility buffer in packed format" },
//     { "laserviewW",    "gLaserViewW",       "World-space view direction (xyz float format)", true /* optional */ },
// };

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
const char kTimeGateMode[] = "timeGateMode";
const char kTimeMin[] = "timeMin";
const char kTimeMax[] = "timeMax";
const char kTimeBin[] = "timeBin";
const char kSamplingMethod[] = "samplingMethod";
const char kEmissiveSampler[] = "emissiveSampler";
const char kSpecularRoughnessThreshold[] = "specularRoughnessThresholdEllipsoid";
const char kDoSampleLaser[] = "doSampleLaser";
const char kLaserCollocated[] = "laserCollocated";
const char kUseAlphaTest[] = "useAlphaTest";
const char kUseEllipsoidalMIS[] = "useEllipsoidalMIS";
const char kUseSingleChannel[] = "useSingleChannel";
const char kIsLightSourceLaser[] = "isLightSourceLaser";
const char kShiftmapMethod[] = "shiftmapMethod";
const char kGaugeAxis[] = "gaugeAxis";
const char kGaugeMode[] = "gaugeMode";
const char kNewtonMaxIteration[] = "NewtonMaxIteration";
const char kNewtonRelativeTolerance[] = "NewtonRelativeTolerance";
const char kUseAntitheticSampling[] = "useAntitheticSampling";
const char kPatternTotalBits[] = "patternTotalBits";
const char kPatternCurrentBit[] = "patternCurrentBit";
const char kPatternBaseBit[] = "patternBaseBit";
const char kPatternUseVertical[] = "patternUseVertical";
const char kUseExplicitPatternMapping[] = "useExplicitPatternMapping";
const char kPatternTexturePath[] = "patternTexturePath";
const char kAntitheticIndexTexturePath[] = "antitheticIndexTexturePath";
const char kIntervalIdTexturePath[] = "intervalIdTexturePath";
const char kIntervalTexturePath[] = "intervalTexturePath";
const char kStratifiedSample[] = "stratifiedSample";
} // namespace

MinimalCWToFPathTracer::MinimalCWToFPathTracer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void MinimalCWToFPathTracer::incrementTimeGateFrame()
{
    mPrevTimeGateFrameCount = mTimeGateFrameCount;
    mTimeGateFrameCount += 1;
}

void MinimalCWToFPathTracer::setTimeGateInfo(float timeMin, float timeMax, uint timeBin)
{
    mTimeGateWindow = timeMin;
    mTimeGateWindowRough = timeMax;
    mTimeBin = timeBin;
}

void MinimalCWToFPathTracer::setPatternInfo(uint patternTotalBits, uint patternCurrentBit, uint patternBaseBit, bool patternUseVertical)
{
    mPatternTotalBits = patternTotalBits;
    mPatternCurrentBit = patternCurrentBit;
    mPatternBaseBit = patternBaseBit;
    mPatternUseVertical = patternUseVertical;
}


void MinimalCWToFPathTracer::parseProperties(const Properties& props)
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
        else if (key == kShiftmapMethod)
            mShiftmapMethod = ShiftmapMethodTable[value];
        else if (key == kGaugeAxis)
            mGaugeAxis = value;
        else if (key == kGaugeMode)
            mGaugeMode = GaugeModeTable[value];
        else if(key == kNewtonMaxIteration)
            mNewtonMaxIteration = value;
        else if(key == kNewtonRelativeTolerance)
            mNewtonRelativeTolerance = value;
        else if (key == kUseAntitheticSampling)
            mUseAntitheticSampling = value;
        else if (key == kStratifiedSample)
            mStratifiedSample = value;
        else if (key == kPatternTotalBits)
            mPatternTotalBits = value;
        else if (key == kPatternCurrentBit)
            mPatternCurrentBit = value;
        else if (key == kPatternBaseBit)
            mPatternBaseBit = value;
        else if (key == kPatternUseVertical)
            mPatternUseVertical = value;
        else if (key == kUseExplicitPatternMapping)
            mUseExplicitPatternMapping = value;
        else if (key == kPatternTexturePath)
            mPatternTexturePath = (std::string)value;
        else if (key == kAntitheticIndexTexturePath)
            mAntitheticIndexTexturePath = (std::string)value;
        else if (key == kIntervalIdTexturePath)
            mIntervalIdTexturePath = (std::string)value;
        else if (key == kIntervalTexturePath)
            mIntervalTexturePath = (std::string)value;
        else
            logWarning("Unknown property '{}' in MinimalCWToFPathTracer properties.", key);
    }
}

Properties MinimalCWToFPathTracer::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    return props;
}

RenderPassReflection MinimalCWToFPathTracer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    // addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

DefineList MinimalCWToFPathTracer::getShaderDefines(const RenderData& renderData) const{
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
    defines.add("USE_ANTITHETIC_SAMPLING", mUseAntitheticSampling ? "1" : "0");
    defines.add("USE_STRATIFIED_SAMPLING", mStratifiedSample > 0 ? "1" : "0");
    
    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mSamplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::DIRECT));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL));
    defines.add("USE_ELLIPSOIDAL_DIRECT_MIS", mUseEllipsoidalMIS ? "1" : "0");
    defines.add("TRIANGLE_APPROX", std::to_string((uint32_t)TimeGatedSamplingMethod::TRIANGLE_APPROX));
    defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)mShiftmapMethod));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    // defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    return defines;
}

void MinimalCWToFPathTracer::updateLaserInfo(
    const float3& position, 
    const float3& direction, 
    const float3& power,
    const float cosAngle
){
    mLaserOrigin = position;
    mLaserDirection = direction;
    mLaserPower = power;
    mLaserCosAngle = cosAngle;
}

void MinimalCWToFPathTracer::bindShaderData(const ShaderVar& var, const RenderData& renderData)
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
    
    var["CB"]["gPatternTotalBits" ] = mPatternTotalBits;
    var["CB"]["gPatternCurrentBit" ] = mPatternCurrentBit;
    var["CB"]["gPatternBaseBit" ] = mPatternBaseBit;
    var["CB"]["gPatternUseVertical" ] = mPatternUseVertical;
    var["CB"]["gStratifiedSample" ] = mStratifiedSample;
    
    if(mUseExplicitPatternMapping){
        var["CB_pattern"]["patternTex"] = mpPatternTexture;
        if(mpAntitheticIndexTexture) var["CB_pattern"]["antiIndex"] = mpAntitheticIndexTexture;
        if(mpIntervalIdTex) var["CB_pattern"]["intervalIdTex"] = mpIntervalIdTex;
        if(mpIntervalTex) var["CB_pattern"]["intervalTex"] = mpIntervalTex;
    }

    var["Shiftmap_CB"]["gGaugeAxis"] = mGaugeAxis;
    var["Shiftmap_CB"]["gGaugeMode"] = uint(mGaugeMode);
    var["Shiftmap_CB"]["gShiftMappingMethod"] = uint(mShiftmapMethod);
    var["Shiftmap_CB"]["gNewtonMaxIteration"] = mNewtonMaxIteration;
    var["Shiftmap_CB"]["gNewtonRelativeTolerance"] = mNewtonRelativeTolerance;

    // transients
    if(mLaserCollocated && mpScene){
        var["CB"]["laserOrigin"] = mpScene->getCamera()->getPosition();
        var["CB"]["laserDirection"] = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    } else {
        var["CB"]["laserOrigin"] = mLaserOrigin;
        var["CB"]["laserDirection"] = mLaserDirection;
    }
    var["CB"]["laserPower"] = mLaserPower;
    var["CB"]["laserCosAngle"] = mLaserCosAngle;
    var["CB"]["samplesPerPixel"] = mSamplesPerPixel;

    // var["CB"]["doSampleLaser"] = mDoSampleLaser;
    
    var["TimeGate"]["time_gate_window"] = mTimeGateWindow;
    var["TimeGate"]["time_gate_window_rough"] = mTimeGateWindowRough;
    var["TimeGate"]["time_gate_mode"] = uint(mTimeGateMode);

    var["TimeGate"]["tcurr"] = mTcurr;
    var["TimeGate"]["tprev"] = mTprev;

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
    // for (auto channel : kLaserInputChannels)
    //     bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);
}

void MinimalCWToFPathTracer::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

    if(mUseExplicitPatternMapping && !mpPatternTexture){
        auto patternData   = loadUintArrayFromTxt(mPatternTexturePath);
        mpPatternTexture   = createUintTexture1D(patternData);
        
        auto intervalIdData   = loadUintArrayFromTxt(mIntervalIdTexturePath);
        mpIntervalIdTex   = createUintTexture1D(intervalIdData);
        
        auto intervalData   = loadUintArrayFromTxt(mIntervalTexturePath);
        mpIntervalTex   = createUintTexture1D(intervalData);
        
        auto antiIndexData = loadUintArrayFromTxt(mAntitheticIndexTexturePath);
        mpAntitheticIndexTexture = createUintTexture1D(antiIndexData);
    }

    // update time
    mTcurr = float((float(mTimeGateFrameCount % mTimeBin) / mTimeBin) * (mTimeMax - mTimeMin) + mTimeMin);
    mTprev = float((float(mPrevTimeGateFrameCount % mTimeBin) / mTimeBin) * (mTimeMax - mTimeMin) + mTimeMin);
    mPrevTimeGateFrameCount = mTimeGateFrameCount;

    if (!mpEmissiveSampler && (mSamplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL))
    {
        const auto& pLights = mpScene->getITriCollection(pRenderContext);
        FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
        FALCOR_ASSERT(!mpEmissiveSampler);

        mLightBVHOptions.buildOptions.maxTriangleCountPerLeaf = 1;
        
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

void MinimalCWToFPathTracer::renderUI(Gui::Widgets& widget)
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

void MinimalCWToFPathTracer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;

    // Set new scene.
    mpScene = pScene;
}

ref<Texture> MinimalCWToFPathTracer::createUintTexture1D(const std::vector<uint32_t>& data)
{
    uint32_t width = (uint32_t)data.size();

    return mpDevice->createTexture1D(
        width,
        ResourceFormat::R32Uint,  // IMPORTANT
        1,                        // mip levels
        1,                        // array size
        data.data()
    );
}

