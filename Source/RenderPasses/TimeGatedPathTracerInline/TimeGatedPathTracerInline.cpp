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

const char kShowLaserSpot[] = "showLaserSpot";
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
    auto timeGate = mOptions.timeGate;
    timeGate.timeMin = timeMin;
    timeGate.timeMax = timeMax;
    timeGate.timeBin = timeBin;
    timeGate.validate();
    if (timeGate.timeMin != mOptions.timeGate.timeMin || timeGate.timeMax != mOptions.timeGate.timeMax ||
        timeGate.timeBin != mOptions.timeGate.timeBin)
    {
        mOptions.timeGate = timeGate;
        mOptionsChanged = true;
    }
}

void TimeGatedPathTracerInline::validateOptions(const Options& options)
{
    options.timeGate.validate();
    options.pathTracing.validate();
}

void TimeGatedPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.timeGate.parse(key, value) || mOptions.sampling.parse(key, value) || mOptions.pathTracing.parse(key, value))
            continue;
        if (key == kShowLaserSpot)
            mOptions.showLaserSpot = value;
        else
            logWarning("Unknown property '{}' in TimeGatedPathTracerInline properties.", key);
    }
    mOptions.timeGate.applyTimeCenter(props);
}

Properties TimeGatedPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.timeGate.serialize(props);
    mOptions.sampling.serialize(props);
    mOptions.pathTracing.serialize(props);
    props[kShowLaserSpot] = mOptions.showLaserSpot;
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

    defines.add("MAX_BOUNCES", std::to_string(mOptions.pathTracing.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.pathTracing.computeDirect ? "1" : "0");
    defines.add("SHOW_LASER_SPOT", mOptions.showLaserSpot ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.pathTracing.isLightSourceLaser ? "1" : "0");

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.sampling.samplingMethod));
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
    var["CB"]["specularRoughnessThreshold"] = mOptions.sampling.ellipsoidRoughnessThreshold;

    // Resolve laser settings from the camera or the upstream laser pass.
    if (mOptions.pathTracing.laserCollocated && mpScene)
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

    var["CB"]["samplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;

    var["TimeGate"]["time_gate_window"] = mOptions.timeGate.timeGateWindow;
    var["TimeGate"]["time_gate_mode"] = uint(mOptions.timeGate.timeGateMode);

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
    mFrameState.gatePosition = mOptions.timeGate.gateCenter(mFrameState.gateIndex);
    mFrameState.previousGatePosition = mOptions.timeGate.gateCenter(mFrameState.previousGateIndex);
    mFrameState.previousGateIndex = mFrameState.gateIndex;
}

void TimeGatedPathTracerInline::prepareLightSampler(RenderContext* pRenderContext)
{
    const bool useEllipsoidalSampling = mOptions.sampling.samplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL ||
                                       mOptions.sampling.samplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS;
    if (!mpEmissiveSampler && useEllipsoidalSampling)
    {
        const auto& pLights = mpScene->getITriCollection(pRenderContext);
        FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);

        mLightBVHOptions.buildOptions.maxTriangleCountPerLeaf = 1;

        switch (mOptions.sampling.triSampler)
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
    if (mOptions.timeGate.shiftGate && mOptions.timeGate.timeMax > mOptions.timeGate.timeMin)
        incrementTimeGateFrame();
}

void TimeGatedPathTracerInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    auto options = mOptions;

    if (auto group = widget.group("Time gate", true))
        dirty |= options.timeGate.renderUI(group, mFrameState.gatePosition);

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the laser spot.");
        dirty |= options.sampling.renderUI(group, true);
    }

    if (auto group = widget.group("Light", true))
        dirty |= options.pathTracing.renderLightUI(group);

    if (auto group = widget.group("Output", true))
    {
        dirty |= options.pathTracing.renderOutputUI(group, true);
        dirty |= group.checkbox("Show laser spot", options.showLaserSpot);
        group.tooltip("Debug overlay: adds the laser spot seen directly from the primary hit (red channel, not time "
                      "gated).", true);
    }

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        validateOptions(options);
        // Rebuild the sampler and program: the emissive sampler's defines are only added when the program is created.
        if (options.sampling.triSampler != mOptions.sampling.triSampler)
            mpEmissiveSampler.reset();
        if (options.sampling.samplingMethod != mOptions.sampling.samplingMethod || options.sampling.triSampler != mOptions.sampling.triSampler)
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
