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
#include "TimeGatedPathTracerInline.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EmissiveUniformSampler.h"
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regTimeGatedPathTracerInline(pybind11::module& m)
{
    pybind11::class_<TimeGatedPathTracerInline, RenderPass, ref<TimeGatedPathTracerInline>> pass(m, "TimeGatedPathTracerInline");
    pass.def("increment_time_gate_frame", &TimeGatedPathTracerInline::incrementTimeGateFrame);
    pass.def("set_time_gate_info", &TimeGatedPathTracerInline::setTimeGateInfo);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TimeGatedPathTracerInline>();
    ScriptBindings::registerBinding(regTimeGatedPathTracerInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TimeGatedPathTracerInline/TimeGatedPathTracerInline.cs.slang";
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

const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kShowLaserSpot[] = "showLaserSpot";
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kSamplesPerPixel[] = "samplesPerPixel";
const char kTimeGateWindow[] = "timeGateWindow";
const char kTimeGateMode[] = "timeGateMode";
const char kTimeMin[] = "timeMin";
const char kTimeMax[] = "timeMax";
const char kTimeBin[] = "timeBin";
const char kShiftGate[] = "shiftGate";
const char kSamplingMethod[] = "samplingMethod";
const char kEmissiveSampler[] = "emissiveSampler";
const char kSpecularRoughnessThreshold[] = "specularRoughnessThresholdEllipsoid";
const char kLaserCollocated[] = "laserCollocated";
const char kUseAlphaTest[] = "useAlphaTest";
const char kUseSingleChannel[] = "useSingleChannel";
const char kIsLightSourceLaser[] = "isLightSourceLaser";
template<typename T>
T parseEnum(const std::unordered_map<std::string, T>& values, const std::string& name, const char* property)
{
    auto it = values.find(name);
    if (it == values.end())
        FALCOR_THROW("Invalid value '{}' for '{}'.", name, property);
    return it->second;
}

template<typename T>
std::string enumName(const std::unordered_map<std::string, T>& values, T value)
{
    for (const auto& [name, candidate] : values)
        if (candidate == value)
            return name;
    FALCOR_THROW("Cannot serialize invalid enum value.");
}
} // namespace

TimeGatedPathTracerInline::TimeGatedPathTracerInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void TimeGatedPathTracerInline::incrementTimeGateFrame()
{
    mFrameState.previousGateIndex = mFrameState.gateIndex;
    mFrameState.gateIndex += 1;
    mOptionsChanged = true; // Downstream accumulation must not mix different gates.
}

void TimeGatedPathTracerInline::setTimeGateInfo(float timeMin, float timeMax, uint timeBin)
{
    auto options = mOptions;
    options.timeMin = timeMin;
    options.timeMax = timeMax;
    options.timeBin = timeBin;
    validateOptions(options);
    if (options.timeMin != mOptions.timeMin || options.timeMax != mOptions.timeMax || options.timeBin != mOptions.timeBin)
    {
        mOptions = options;
        mOptionsChanged = true;
    }
}

const std::unordered_map<std::string, TimeGatedPathTracerInline::TimeGatedSamplingMethod>&
TimeGatedPathTracerInline::getSamplingMethods()
{
    static const std::unordered_map<std::string, TimeGatedSamplingMethod> methods = {
        {"direct", TimeGatedSamplingMethod::DIRECT},
        {"ellipsoidal", TimeGatedSamplingMethod::ELLIPSOIDAL},
        {"ellipsoidal_direct_mis", TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS},
    };
    return methods;
}

void TimeGatedPathTracerInline::validateOptions(const Options& options)
{
    if (options.timeBin == 0 || options.samplesPerPixel == 0)
        FALCOR_THROW("timeBin and samplesPerPixel must be greater than zero.");
    if (!std::isfinite(options.timeGateWindow) || options.timeGateWindow <= 0.f)
        FALCOR_THROW("timeGateWindow must be finite and greater than zero.");
    // Equal endpoints intentionally select a fixed gate for offline rendering.
    if (!std::isfinite(options.timeMin) || !std::isfinite(options.timeMax) || options.timeMin > options.timeMax)
        FALCOR_THROW("The gate range must be finite with timeMin <= timeMax.");
}

void TimeGatedPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxBounces)
            mOptions.maxBounces = value;
        else if (key == kComputeDirect)
            mOptions.computeDirect = value;
        else if (key == kShowLaserSpot)
            mOptions.showLaserSpot = value;
        else if (key == kUseImportanceSampling)
            mOptions.useImportanceSampling = value;
        else if (key == kSamplesPerPixel)
            mOptions.samplesPerPixel = value;
        else if (key == kTimeGateMode)
            mOptions.timeGateMode = parseEnum(TimeGateModeTable, std::string(value), kTimeGateMode);
        else if (key == kTimeGateWindow)
            mOptions.timeGateWindow = value;
        else if (key == kTimeMin)
            mOptions.timeMin = value;
        else if (key == kTimeMax)
            mOptions.timeMax = value;
        else if (key == kTimeBin)
            mOptions.timeBin = value;
        else if (key == kShiftGate)
            mOptions.shiftGate = value;
        else if (key == kSamplingMethod)
            mOptions.samplingMethod = parseEnum(getSamplingMethods(), std::string(value), kSamplingMethod);
        else if (key == kEmissiveSampler)
            mOptions.triSampler = value;
        else if (key == kSpecularRoughnessThreshold)
            mOptions.specularRoughnessThreshold = value;
        else if (key == kLaserCollocated)
            mOptions.laserCollocated = value;
        else if (key == kUseAlphaTest)
            mOptions.useAlphaTest = value;
        else if (key == kUseSingleChannel)
            mOptions.useSingleChannel = value;
        else if (key == kIsLightSourceLaser)
            mOptions.isLightSourceLaser = value;
        else
            logWarning("Unknown property '{}' in TimeGatedPathTracerInline properties.", key);
    }
}

Properties TimeGatedPathTracerInline::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mOptions.maxBounces;
    props[kComputeDirect] = mOptions.computeDirect;
    props[kShowLaserSpot] = mOptions.showLaserSpot;
    props[kUseImportanceSampling] = mOptions.useImportanceSampling;
    props[kSamplesPerPixel] = mOptions.samplesPerPixel;
    props[kTimeGateMode] = enumName(TimeGateModeTable, mOptions.timeGateMode);
    props[kTimeGateWindow] = mOptions.timeGateWindow;
    props[kTimeMin] = mOptions.timeMin;
    props[kTimeMax] = mOptions.timeMax;
    props[kTimeBin] = mOptions.timeBin;
    props[kShiftGate] = mOptions.shiftGate;
    props[kSamplingMethod] = enumName(getSamplingMethods(), mOptions.samplingMethod);
    props[kEmissiveSampler] = mOptions.triSampler;
    props[kSpecularRoughnessThreshold] = mOptions.specularRoughnessThreshold;
    props[kLaserCollocated] = mOptions.laserCollocated;
    props[kUseAlphaTest] = mOptions.useAlphaTest;
    props[kUseSingleChannel] = mOptions.useSingleChannel;
    props[kIsLightSourceLaser] = mOptions.isLightSourceLaser;
    return props;
}

RenderPassReflection TimeGatedPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

DefineList TimeGatedPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines;

    defines.add("MAX_BOUNCES", std::to_string(mOptions.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.computeDirect ? "1" : "0");
    defines.add("SHOW_LASER_SPOT", mOptions.showLaserSpot ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.useImportanceSampling ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.useSingleChannel ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.isLightSourceLaser ? "1" : "0");

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::DIRECT));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL));
    defines.add("ELLIPSOIDAL_DIRECT_MIS", std::to_string((uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    return defines;
}

void TimeGatedPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();

    if (mpEmissiveSampler)
    {
        mpEmissiveSampler->bindShaderData(var["emissiveSampler"]);
    }

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    var["CB"]["gFrameCount"] = mFrameState.frameCount;
    var["CB"]["gFrameDim"] = targetDim;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["specularRoughnessThreshold"] = mOptions.specularRoughnessThreshold;

    // Resolve laser settings from the camera or the upstream laser pass.
    if (mOptions.laserCollocated && mpScene)
    {
        var["CB"]["laserOrigin"] = mpScene->getCamera()->getPosition();
        var["CB"]["laserDirection"] = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    }
    else
    {
        var["CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
        var["CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    }
    var["CB"]["laserPower"] = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    var["CB"]["laserCosAngle"] = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;

    var["CB"]["samplesPerPixel"] = mOptions.samplesPerPixel;

    var["TimeGate"]["time_gate_window"] = mOptions.timeGateWindow;
    var["TimeGate"]["time_gate_mode"] = uint(mOptions.timeGateMode);

    var["TimeGate"]["tcurr"] = mFrameState.gatePosition;
    var["TimeGate"]["tprev"] = mFrameState.previousGatePosition;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (const auto& channel : kInputChannels)
        bind(channel);
    for (const auto& channel : kLaserInputChannels)
        bind(channel);
    for (const auto& channel : kOutputChannels)
        bind(channel);
}

void TimeGatedPathTracerInline::updateGatePosition()
{
    // Preserve the half-open scan range and fixed-gate behavior (min == max).
    const auto positionAt = [this](uint index)
    {
        return (float(index % mOptions.timeBin) / mOptions.timeBin) * (mOptions.timeMax - mOptions.timeMin) + mOptions.timeMin;
    };
    mFrameState.gatePosition = positionAt(mFrameState.gateIndex);
    mFrameState.previousGatePosition = positionAt(mFrameState.previousGateIndex);
    mFrameState.previousGateIndex = mFrameState.gateIndex;
}

void TimeGatedPathTracerInline::prepareLightSampler(RenderContext* pRenderContext)
{
    const bool useEllipsoidalSampling = mOptions.samplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL ||
                                       mOptions.samplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS;
    if (!mpEmissiveSampler && useEllipsoidalSampling)
    {
        const auto& pLights = mpScene->getITriCollection(pRenderContext);
        FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);

        mLightBVHOptions.buildOptions.maxTriangleCountPerLeaf = 1;

        switch (mOptions.triSampler)
        {
        case EmissiveLightSamplerType::Uniform:
            mpEmissiveSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, pLights);
            break;
        case EmissiveLightSamplerType::LightBVH:
            mpEmissiveSampler = std::make_unique<LightBVHSampler>(pRenderContext, pLights, mLightBVHOptions);
            break;
        case EmissiveLightSamplerType::Power:
            mpEmissiveSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, pLights);
            break;
        default:
            FALCOR_THROW("Unknown emissive light sampler type");
        }
        mpEmissiveSampler->update(pRenderContext, pLights);
    }
}

void TimeGatedPathTracerInline::prepareProgram(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpComputePass)
    {
        // Create the inline-raytracing compute program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getShaderDefines(renderData));

        if (mpEmissiveSampler)
            defines.add(mpEmissiveSampler->getDefines());

        mpComputePass = ComputePass::create(mpDevice, desc, defines, true);

        // Bind static resources
        ShaderVar var = mpComputePass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
    }
}

void TimeGatedPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
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
        for (const auto& it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    updateGatePosition();
    prepareLightSampler(pRenderContext);
    prepareProgram(pRenderContext, renderData);

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

    if (mpEmissiveSampler)
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

    // Bind per-frame constants and resources.
    auto var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    // Spawn the rays.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpComputePass->execute(pRenderContext, uint3(targetDim, 1));

    mFrameState.frameCount++;
    if (mOptions.shiftGate && mOptions.timeMax > mOptions.timeMin)
        incrementTimeGateFrame();
}

void TimeGatedPathTracerInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    auto options = mOptions;

    if (auto group = widget.group("Time gate", true))
    {
        // Only the kernels implemented by pathLengthImportance() are offered.
        static const Gui::DropdownList kTimeGateModeList = {
            {(uint32_t)TimeGateMode::BOX, "Box"},
            {(uint32_t)TimeGateMode::TENT, "Tent"},
            {(uint32_t)TimeGateMode::COS, "Cos"},
            {(uint32_t)TimeGateMode::ALL, "All (no gating)"},
        };
        uint32_t timeGateMode = (uint32_t)options.timeGateMode;
        if (group.dropdown("Gate kernel", kTimeGateModeList, timeGateMode))
        {
            options.timeGateMode = (TimeGateMode)timeGateMode;
            dirty = true;
        }
        group.tooltip("Weight of a path as a function of its total optical length (laser -> scene -> camera) "
                      "relative to the gate center.", true);

        dirty |= group.var("Gate window", options.timeGateWindow, 0.001f, 1000.0f);
        group.tooltip("Gate width in path-length units (scene units). The output is divided by it.", true);

        dirty |= group.checkbox("Shift gate", options.shiftGate);
        group.tooltip("Off: a fixed gate at Gate center.\nOn: the gate moves one step per frame from Gate min "
                      "toward Gate max, then starts again at Gate min.", true);

        if (!options.shiftGate)
        {
            float gateCenter = options.timeMin;
            if (group.var("Gate center", gateCenter, 0.0f, 1000.0f))
            {
                options.timeMin = options.timeMax = gateCenter;
                dirty = true;
            }
            group.tooltip("Gate center in path-length units.", true);
        }
        else
        {
            dirty |= group.var("Gate min", options.timeMin, 0.0f, options.timeMax);
            group.tooltip("First gate center, in path-length units.", true);

            dirty |= group.var("Gate max", options.timeMax, options.timeMin, 1000.0f);
            group.tooltip("End of the scan, in path-length units. The last gate center is Gate max - Gate step.", true);

            dirty |= group.var("Gate bins", options.timeBin, 1u, 1u << 16);
            group.tooltip("Number of gate centers from Gate min to Gate max.", true);

            // The step is derived from the bins; editing it picks the nearest bin count.
            const float range = options.timeMax - options.timeMin;
            float gateStep = range / options.timeBin;
            if (range > 0.f && group.var("Gate step", gateStep, 1e-4f, range))
            {
                options.timeBin = std::max(1u, (uint)std::lround(range / gateStep));
                dirty = true;
            }
            group.tooltip("Gate center shift per frame, in path-length units. Sets Gate bins to the nearest count.", true);
            if (range <= 0.f)
                group.text("Set Gate max above Gate min to shift the gate.");
        }

        group.text(fmt::format("Current gate center: {:.4f}", mFrameState.gatePosition));
    }

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= group.var("Samples per pixel", options.samplesPerPixel, 1u, 1024u);
        group.tooltip("Camera paths traced per pixel in each frame.", true);

        dirty |= group.var("Max bounces", options.maxBounces, 0u, 1u << 16);
        group.tooltip("Maximum number of surface vertices on the camera path, counting the primary hit and any "
                      "vertex inserted by an ellipsoidal connection. Each vertex is connected to the laser spot.", true);

        static const Gui::DropdownList kSamplingMethodList = {
            {(uint32_t)TimeGatedSamplingMethod::DIRECT, "Direct"},
            {(uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL, "Ellipsoidal"},
            {(uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS, "Ellipsoidal + direct (MIS)"},
        };
        uint32_t samplingMethod = (uint32_t)options.samplingMethod;
        if (group.dropdown("Sampling method", kSamplingMethodList, samplingMethod))
        {
            options.samplingMethod = (TimeGatedSamplingMethod)samplingMethod;
            dirty = true;
        }
        group.tooltip("How a camera-path vertex x is connected to the laser spot:\n"
                      "Direct: connect x -> laser spot.\n"
                      "Ellipsoidal: insert a vertex y on the ellipsoid of paths x -> y -> laser spot whose length "
                      "matches the gate.\n"
                      "Ellipsoidal + direct (MIS): both, combined with the balance heuristic.", true);

        if (options.samplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL)
        {
            dirty |= group.var("Ellipsoid roughness threshold", options.specularRoughnessThreshold, 0.f, 1.f);
            group.tooltip("Use an ellipsoidal connection at x only if its roughness is above this value; smoother "
                          "vertices use a direct connection from the next vertex instead.", true);
        }

        if (options.samplingMethod != TimeGatedSamplingMethod::DIRECT)
        {
            static const Gui::DropdownList kTriangleSamplerList = {
                {(uint32_t)EmissiveLightSamplerType::Uniform, "Uniform"},
                {(uint32_t)EmissiveLightSamplerType::LightBVH, "LightBVH"},
                {(uint32_t)EmissiveLightSamplerType::Power, "Power"},
            };
            uint32_t triSampler = (uint32_t)options.triSampler;
            if (group.dropdown("Ellipsoid triangle sampler", kTriangleSamplerList, triSampler))
            {
                options.triSampler = (EmissiveLightSamplerType)triSampler;
                dirty = true;
            }
            group.tooltip("How an ellipsoidal connection selects the scene triangle on which it places y.", true);
        }

        dirty |= group.checkbox("Use importance sampling", options.useImportanceSampling);
        group.tooltip("Importance-sample the BSDF when extending the camera path. Off: the material's reference "
                      "sampler (cosine-weighted for standard materials).", true);
    }

    if (auto group = widget.group("Light", true))
    {
        dirty |= group.checkbox("Laser source", options.isLightSourceLaser);
        group.tooltip("On: the light is the spot where the laser beam hits the scene, and the beam length adds to "
                      "the path length.\nOff: a point light at the laser position.", true);

        dirty |= group.checkbox("Laser at camera", options.laserCollocated);
        group.tooltip("Place the laser at the camera, aimed at the camera target, instead of using the laser pass "
                      "position and direction.", true);
    }

    if (auto group = widget.group("Output", true))
    {
        dirty |= group.checkbox("Primary-hit direct", options.computeDirect);
        group.tooltip("Include the shortest path, camera -> primary hit -> laser spot (time gated).", true);

        dirty |= group.checkbox("Show laser spot", options.showLaserSpot);
        group.tooltip("Debug overlay: adds the laser spot seen directly from the primary hit (red channel, not time "
                      "gated).", true);

        dirty |= group.checkbox("Single channel", options.useSingleChannel);
        group.tooltip("Copy the red channel to green and blue.", true);

        dirty |= group.checkbox("Alpha test", options.useAlphaTest);
        group.tooltip("Honor alpha-tested (cutout) materials when tracing rays.", true);
    }

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        validateOptions(options);
        // Rebuild the sampler and program: the emissive sampler's defines are only added when the program is created.
        if (options.triSampler != mOptions.triSampler)
            mpEmissiveSampler.reset();
        if (options.samplingMethod != mOptions.samplingMethod || options.triSampler != mOptions.triSampler)
            mpComputePass = nullptr;
        mOptions = options;
        mOptionsChanged = true;
    }
}

void TimeGatedPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mpComputePass = nullptr;
    mpEmissiveSampler.reset();
    mFrameState.frameCount = 0;
    mOptionsChanged = true;
    // Preserve the scripted gate index when replacing the scene.

    // Set new scene.
    mpScene = pScene;
}
