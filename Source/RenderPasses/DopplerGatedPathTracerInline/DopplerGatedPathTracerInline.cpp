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
#include "DopplerGatedPathTracerInline.h"
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regDopplerGatedPathTracerInline(pybind11::module& m)
{
    using namespace pybind11::literals;
    pybind11::class_<DopplerGatedPathTracerInline, RenderPass, ref<DopplerGatedPathTracerInline>> pass(
        m, "DopplerGatedPathTracerInline");
    pass.def("set_velocity", &DopplerGatedPathTracerInline::setVelocity, "name"_a, "linear"_a,
        "angular"_a = float3(0.f), "center"_a = float3(0.f));
    pass.def("clear_velocities", &DopplerGatedPathTracerInline::clearVelocities);
    pass.def("get_object_names", &DopplerGatedPathTracerInline::getObjectNames);
    pass.def("increment_frequency_gate_frame", &DopplerGatedPathTracerInline::incrementFrequencyGateFrame);
    pass.def("set_frequency_gate_info", &DopplerGatedPathTracerInline::setFrequencyGateInfo);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, DopplerGatedPathTracerInline>();
    ScriptBindings::registerBinding(regDopplerGatedPathTracerInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/DopplerGatedPathTracerInline/DopplerGatedPathTracerInline.cs.slang";
const char kPassName[] = "DopplerGatedPathTracerInline";

const char kWavelength[] = "wavelength";
const char kFrequencyCenter[] = "frequencyCenter";
const char kSensorVelocity[] = "sensorVelocity";
const char kLightVelocity[] = "lightVelocity";
const char kVelocities[] = "velocities";

/// This pass's gate properties and the time gate's that they set.
const std::pair<const char*, const char*> kGateProperties[] = {
    {"frequencyMin", "timeMin"},
    {"frequencyMax", "timeMax"},
    {"frequencyBin", "timeBin"},
    {"frequencyGateWindow", "timeGateWindow"},
    {"frequencyGateMode", "timeGateMode"},
    {"shiftGate", "shiftGate"},
};
} // namespace

DopplerGatedPathTracerInline::DopplerGatedPathTracerInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void DopplerGatedPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.pathTracing.parse(key, value))
            continue;
        bool gateProperty = key == kFrequencyCenter; // Applied after all properties.
        for (const auto& [name, timeGateName] : kGateProperties)
            if (key == name)
                gateProperty = mOptions.gate.parse(timeGateName, value);
        if (gateProperty)
            continue;
        if (key == kWavelength)
            mOptions.wavelength = value;
        else if (key == kSensorVelocity)
            mOptions.sensorVelocity = value;
        else if (key == kLightVelocity)
            mOptions.lightVelocity = value;
        else if (key == kVelocities)
            mOptions.velocities = parseObjectMotions(value);
        else
            logWarning("Unknown property '{}' in {} properties.", key, kPassName);
    }
    // A fixed gate: frequencyMin = frequencyMax = frequencyCenter, whatever the order of the properties.
    if (props.has(kFrequencyCenter))
        mOptions.gate.timeMin = mOptions.gate.timeMax = props.get<float>(kFrequencyCenter);
}

void DopplerGatedPathTracerInline::validateOptions(const Options& options)
{
    options.pathTracing.validate();
    options.gate.validate();
    if (!(options.wavelength > 0.f) || !std::isfinite(options.wavelength))
        FALCOR_THROW("wavelength must be positive and finite.");
}

void DopplerGatedPathTracerInline::setProperties(const Properties& props)
{
    // Invalid properties throw and leave the options unchanged.
    InlinePass::applyProperties(mOptions, [&] { parseProperties(props); }, validateOptions);
    if (props.has(kVelocities))
        mVelocitiesDirty = true;
    mOptionsChanged = true;
}

Properties DopplerGatedPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.pathTracing.serialize(props);
    const TimeGateConfig& gate = mOptions.gate;
    props["frequencyMin"] = gate.timeMin;
    props["frequencyMax"] = gate.timeMax;
    props["frequencyBin"] = gate.timeBin;
    props["frequencyGateWindow"] = gate.timeGateWindow;
    props["frequencyGateMode"] = enumPropertyName(kTimeGateModes, gate.timeGateMode);
    props["shiftGate"] = gate.shiftGate;
    props[kWavelength] = mOptions.wavelength;
    props[kSensorVelocity] = mOptions.sensorVelocity;
    props[kLightVelocity] = mOptions.lightVelocity;
    props[kVelocities] = serializeObjectMotions(mOptions.velocities);
    return props;
}

RenderPassReflection DopplerGatedPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitInputChannels);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels);
    return reflector;
}

DefineList DopplerGatedPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(mLaserInput.get().getDefines());
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    return defines;
}

void DopplerGatedPathTracerInline::setVelocity(const std::string& name, float3 linear, float3 angular, float3 center)
{
    mOptions.velocities[name] = ObjectMotion{linear, angular, center};
    mVelocitiesDirty = true;
    mOptionsChanged = true;
}

void DopplerGatedPathTracerInline::clearVelocities()
{
    mOptions.velocities.clear();
    mVelocitiesDirty = true;
    mOptionsChanged = true;
}

std::vector<std::tuple<uint32_t, std::string, std::string, bool>> DopplerGatedPathTracerInline::getObjectNames() const
{
    std::vector<std::tuple<uint32_t, std::string, std::string, bool>> names;
    if (mpScene)
        for (const auto& object : listSceneObjects(*mpScene))
            names.emplace_back(object.instance, object.mesh, object.material, object.movable);
    return names;
}

void DopplerGatedPathTracerInline::incrementFrequencyGateFrame()
{
    mGate.advance();
    mOptionsChanged = true; // Downstream accumulation must not mix different gates.
}

void DopplerGatedPathTracerInline::setFrequencyGateInfo(float frequencyMin, float frequencyMax, uint frequencyBin)
{
    TimeGateConfig gate = mOptions.gate;
    gate.timeMin = frequencyMin;
    gate.timeMax = frequencyMax;
    gate.timeBin = frequencyBin;
    gate.validate();
    if (gate.timeMin != mOptions.gate.timeMin || gate.timeMax != mOptions.gate.timeMax || gate.timeBin != mOptions.gate.timeBin)
    {
        mOptions.gate = gate;
        mOptionsChanged = true;
    }
}

void DopplerGatedPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    // Doppler shift per unit path velocity: f0 / c = 1 / wavelength, in MHz per m/s (wavelength in nm).
    var["CB"]["gShiftPerVelocity"] = 1000.f / mOptions.wavelength;
    var["CB"]["gSensorVelocity"] = mOptions.sensorVelocity;
    var["CB"]["gLightVelocity"] = mOptions.lightVelocity;
    var["gInstanceVelocities"] = mpInstanceVelocities;
    mLaserInput.get().bindShaderData(var["Laser"]);
    mOptions.gate.bindShaderData(var["TimeGate"], mGate);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
}

void DopplerGatedPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    mLaserInput.update(renderData, "DopplerGatedPathTracerInline");
    if (mOptionsChanged)
    {
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }
    if (!mpScene)
    {
        InlinePass::clearChannels(pRenderContext, renderData, InlinePass::kColorOutputChannels);
        return;
    }

    mOptions.gate.beginFrame(mGate);
    if (mVelocitiesDirty || !mpInstanceVelocities)
    {
        mpInstanceVelocities = createInstanceVelocityBuffer(mpDevice, *mpScene, mOptions.velocities, kPassName);
        mVelocitiesDirty = false;
    }
    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile,
            getShaderDefines(renderData));
    InlinePass::checkScene(*mpScene, renderData);
    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator, getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    mpComputePass->execute(pRenderContext, uint3(renderData.getDefaultTextureDims(), 1));

    mFrameCount++;
    mGate.endFrame();
    if (mOptions.gate.shiftGate && mOptions.gate.timeMax > mOptions.gate.timeMin)
        incrementFrequencyGateFrame();
}

void DopplerGatedPathTracerInline::renderUI(Gui::Widgets& widget)
{
    Options options = mOptions;
    bool dirty = false;

    if (auto group = widget.group("Doppler gate", true))
    {
        dirty |= group.var("Wavelength (nm)", options.wavelength, 1.f, 100000.f);
        group.tooltip("Laser wavelength. The Doppler shift of a path is its path velocity / wavelength.", true);
        dirty |= renderTimeGateModeUI(group, options.gate.timeGateMode);
        group.tooltip("Weight of a path as a function of its Doppler shift relative to the gate center.", true);
        dirty |= group.var("Gate width (MHz)", options.gate.timeGateWindow, 0.001f, 1e6f);
        group.tooltip("The output is divided by it: radiance per MHz.", true);
        dirty |= group.checkbox("Shift gate", options.gate.shiftGate);
        group.tooltip("Off: a fixed gate at Gate center.\nOn: the gate moves one step per frame from Gate min toward "
                      "Gate max, then starts again at Gate min.", true);
        if (options.gate.shiftGate)
        {
            dirty |= group.var("Gate min (MHz)", options.gate.timeMin, -1e6f, 1e6f);
            dirty |= group.var("Gate max (MHz)", options.gate.timeMax, -1e6f, 1e6f);
            dirty |= group.var("Steps", options.gate.timeBin, 1u, 1u << 16);
            group.text(fmt::format("Current gate center: {:.3f} MHz", mGate.current));
        }
        else
        {
            float center = options.gate.timeMin;
            if (group.var("Gate center (MHz)", center, -1e6f, 1e6f))
            {
                options.gate.timeMin = options.gate.timeMax = center;
                dirty = true;
            }
        }
        group.tooltip("Positive: approaching (the path shortens).", true);
        dirty |= group.var("Sensor velocity (m/s)", options.sensorVelocity, -1e4f, 1e4f);
        dirty |= group.var("Light velocity (m/s)", options.lightVelocity, -1e4f, 1e4f);
    }

    if (auto group = widget.group("Sampling", true))
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the light.");

    if (auto group = widget.group("Output", true))
        dirty |= options.pathTracing.renderOutputUI(group, true, true);

    if (dirty)
    {
        try
        {
            validateOptions(options);
        }
        catch (const std::exception& e)
        {
            mUIWarning = e.what();
            return;
        }
        mUIWarning.clear();
        mOptions = options;
        mOptionsChanged = true;
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void DopplerGatedPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpComputePass = nullptr;
    mFrameCount = 0;
    mVelocitiesDirty = true;
    mOptionsChanged = true;
    mpScene = pScene;
}
