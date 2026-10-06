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
#include "DopplerHistogramPathTracerInline.h"
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regDopplerHistogramPathTracerInline(pybind11::module& m)
{
    using namespace pybind11::literals;
    pybind11::class_<DopplerHistogramPathTracerInline, RenderPass, ref<DopplerHistogramPathTracerInline>> pass(
        m, "DopplerHistogramPathTracerInline");
    pass.def("reset_spectrum", &DopplerHistogramPathTracerInline::resetSpectrum);
    pass.def("set_velocity", &DopplerHistogramPathTracerInline::setVelocity, "name"_a, "linear"_a,
        "angular"_a = float3(0.f), "center"_a = float3(0.f));
    pass.def("clear_velocities", &DopplerHistogramPathTracerInline::clearVelocities);
    pass.def("get_object_names", &DopplerHistogramPathTracerInline::getObjectNames);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, DopplerHistogramPathTracerInline>();
    ScriptBindings::registerBinding(regDopplerHistogramPathTracerInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/DopplerHistogramPathTracerInline/DopplerHistogramPathTracerInline.cs.slang";
const char kPassName[] = "DopplerHistogramPathTracerInline";

const ChannelList kSpectrumOutputChannelSingle = {
    { "spectrum",           "gSpectrum", "Radiance per unit Doppler frequency shift (MHz) per bin", false, ResourceFormat::R32Float },
};

const ChannelList kSpectrumOutputChannelsRGB = {
    { "spectrum",           "gSpectrum", "Radiance per unit Doppler frequency shift (MHz) per bin", false, ResourceFormat::RGBA32Float },
};

// With a chirp (FMCW): the up-chirp spectrum and the down-chirp spectrum.
const ChannelList kChirpSpectrumOutputChannelsSingle = {
    { "spectrum",           "gSpectrum",     "Up-chirp: radiance per unit beat frequency (MHz) per bin", false, ResourceFormat::R32Float },
    { "spectrumDown",       "gSpectrumDown", "Down-chirp: radiance per unit beat frequency (MHz) per bin", false, ResourceFormat::R32Float },
};

const ChannelList kChirpSpectrumOutputChannelsRGB = {
    { "spectrum",           "gSpectrum",     "Up-chirp: radiance per unit beat frequency (MHz) per bin", false, ResourceFormat::RGBA32Float },
    { "spectrumDown",       "gSpectrumDown", "Down-chirp: radiance per unit beat frequency (MHz) per bin", false, ResourceFormat::RGBA32Float },
};

const char kWavelength[] = "wavelength";
const char kChirpBandwidth[] = "chirpBandwidth";
const char kChirpDuration[] = "chirpDuration";
const char kFrequencyMin[] = "frequencyMin";
const char kFrequencyMax[] = "frequencyMax";
const char kFrequencyBin[] = "frequencyBin";
const char kSensorVelocity[] = "sensorVelocity";
const char kLightVelocity[] = "lightVelocity";
const char kVelocities[] = "velocities";
const char kAccumulate[] = "accumulate";
const char kOutputSize[] = "outputSize";
const char kFixedOutputSize[] = "fixedOutputSize";
} // namespace

DopplerHistogramPathTracerInline::DopplerHistogramPathTracerInline(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void DopplerHistogramPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.pathTracing.parse(key, value))
            continue;
        if (key == kWavelength)
            mOptions.wavelength = value;
        else if (key == kChirpBandwidth)
            mOptions.chirpBandwidth = value;
        else if (key == kChirpDuration)
            mOptions.chirpDuration = value;
        else if (key == kFrequencyMin)
            mOptions.frequencyMin = value;
        else if (key == kFrequencyMax)
            mOptions.frequencyMax = value;
        else if (key == kFrequencyBin)
            mOptions.frequencyBin = value;
        else if (key == kSensorVelocity)
            mOptions.sensorVelocity = value;
        else if (key == kLightVelocity)
            mOptions.lightVelocity = value;
        else if (key == kVelocities)
            mOptions.velocities = parseObjectMotions(value);
        else if (key == kAccumulate)
            mOptions.accumulate = value;
        else if (key == kOutputSize)
            mOptions.outputSize = value;
        else if (key == kFixedOutputSize)
            mOptions.fixedOutputSize = value;
        else
            logWarning("Unknown property '{}' in DopplerHistogramPathTracerInline properties.", key);
    }
}

void DopplerHistogramPathTracerInline::validateOptions(const Options& options)
{
    options.pathTracing.validate();
    if (!(options.wavelength > 0.f) || !std::isfinite(options.wavelength))
        FALCOR_THROW("wavelength must be positive and finite.");
    if (!(options.chirpBandwidth >= 0.f) || !std::isfinite(options.chirpBandwidth))
        FALCOR_THROW("chirpBandwidth must be zero (a single-frequency laser) or positive, and finite.");
    if (!(options.chirpDuration > 0.f) || !std::isfinite(options.chirpDuration))
        FALCOR_THROW("chirpDuration must be positive and finite.");
    if (options.frequencyBin == 0)
        FALCOR_THROW("frequencyBin must be positive.");
    if (!std::isfinite(options.frequencyMin) || !std::isfinite(options.frequencyMax) ||
        !(options.frequencyMin < options.frequencyMax))
        FALCOR_THROW("The frequency range must be finite with frequencyMin < frequencyMax.");
}

Properties DopplerHistogramPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.pathTracing.serialize(props);
    props[kWavelength] = mOptions.wavelength;
    props[kChirpBandwidth] = mOptions.chirpBandwidth;
    props[kChirpDuration] = mOptions.chirpDuration;
    props[kFrequencyMin] = mOptions.frequencyMin;
    props[kFrequencyMax] = mOptions.frequencyMax;
    props[kFrequencyBin] = mOptions.frequencyBin;
    props[kSensorVelocity] = mOptions.sensorVelocity;
    props[kLightVelocity] = mOptions.lightVelocity;
    props[kVelocities] = serializeObjectMotions(mOptions.velocities);
    props[kAccumulate] = mOptions.accumulate;
    props[kOutputSize] = mOptions.outputSize;
    if (mOptions.outputSize == RenderPassHelpers::IOSize::Fixed)
        props[kFixedOutputSize] = mOptions.fixedOutputSize;
    return props;
}

RenderPassReflection DopplerHistogramPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitInputChannels);
    const uint2 sz =
        RenderPassHelpers::calculateIOSize(mOptions.outputSize, mOptions.fixedOutputSize, compileData.defaultTexDims);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels, ResourceBindFlags::UnorderedAccess, sz);
    for (const auto& it : spectrumChannels())
    {
        auto& tex = reflector.addOutput(it.name, it.desc).texture3D(sz.x, sz.y, mOptions.frequencyBin);
        tex.bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        tex.format(it.format);
    }
    return reflector;
}

const ChannelList& DopplerHistogramPathTracerInline::spectrumChannels() const
{
    if (mOptions.chirped())
        return mOptions.pathTracing.useSingleChannel ? kChirpSpectrumOutputChannelsSingle : kChirpSpectrumOutputChannelsRGB;
    return mOptions.pathTracing.useSingleChannel ? kSpectrumOutputChannelSingle : kSpectrumOutputChannelsRGB;
}

DefineList DopplerHistogramPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(LaserState::resolve(renderData).getDefines());
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    defines.add(getValidResourceDefines(spectrumChannels(), renderData));
    defines.add("CHIRPED", mOptions.chirped() ? "1" : "0");
    return defines;
}

void DopplerHistogramPathTracerInline::setVelocity(const std::string& name, float3 linear, float3 angular, float3 center)
{
    mOptions.velocities[name] = ObjectMotion{linear, angular, center};
    mVelocitiesDirty = true;
    mOptionsChanged = true;
    resetSpectrum();
}

void DopplerHistogramPathTracerInline::clearVelocities()
{
    mOptions.velocities.clear();
    mVelocitiesDirty = true;
    mOptionsChanged = true;
    resetSpectrum();
}

std::vector<std::tuple<uint32_t, std::string, std::string>> DopplerHistogramPathTracerInline::getObjectNames() const
{
    std::vector<std::tuple<uint32_t, std::string, std::string>> names;
    if (mpScene)
        for (const auto& object : listSceneObjects(*mpScene))
            names.emplace_back(object.instance, object.mesh, object.material);
    return names;
}

void DopplerHistogramPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    // Dispatch over the output, which may have a fixed size.
    const ref<Texture> pColor = renderData.getTexture("color");
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = uint2(pColor->getWidth(), pColor->getHeight());
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gFrequencyMin"] = mOptions.frequencyMin;
    var["CB"]["gFrequencyBinWidth"] = mOptions.binWidth();
    var["CB"]["gFrequencyBin"] = mOptions.frequencyBin;
    // Doppler shift per unit path velocity: f0 / c = 1 / wavelength, in MHz per m/s (wavelength in nm).
    var["CB"]["gShiftPerVelocity"] = 1000.f / mOptions.wavelength;
    // Range term of the beat frequency per unit optical path length, B / (T c), in MHz per meter.
    var["CB"]["gRangeFrequencyPerLength"] = mOptions.rangeFrequencyPerLength();
    var["CB"]["gSensorVelocity"] = mOptions.sensorVelocity;
    var["CB"]["gLightVelocity"] = mOptions.lightVelocity;
    var["gInstanceVelocities"] = mpInstanceVelocities;
    LaserState::resolve(renderData).bindShaderData(var["Laser"]);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
    InlinePass::bindChannels(var, renderData, spectrumChannels());
}

void DopplerHistogramPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }

    if (!mpScene)
    {
        InlinePass::clearChannels(pRenderContext, renderData, InlinePass::kColorOutputChannels);
        InlinePass::clearChannels(pRenderContext, renderData, spectrumChannels());
        return;
    }

    // The shader adds this frame's paths to the bins: clear every frame, or only on reset when accumulating.
    if (mOptions.accumulate && needsReset(renderData))
        resetSpectrum();
    if (!mOptions.accumulate || mNeedToClearSpectrum)
    {
        InlinePass::clearChannels(pRenderContext, renderData, spectrumChannels());
        mNeedToClearSpectrum = false;
        mSummedFrames = 0;
    }

    if (mVelocitiesDirty || !mpInstanceVelocities)
    {
        mpInstanceVelocities = createInstanceVelocityBuffer(mpDevice, *mpScene, mOptions.velocities, kPassName);
        mVelocitiesDirty = false;
    }
    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile,
            getShaderDefines(renderData));
    InlinePass::checkScene(*mpScene, renderData);

    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator,
        getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    const ref<Texture> pColor = renderData.getTexture("color");
    mpComputePass->execute(pRenderContext, uint3(pColor->getWidth(), pColor->getHeight(), 1));

    mFrameCount++;
    mSummedFrames = mOptions.accumulate ? mSummedFrames + 1 : 1;
}

bool DopplerHistogramPathTracerInline::needsReset(const RenderData& renderData) const
{
    // Same rule as AccumulatePass: any refresh flag, or a scene change other than camera jitter/history.
    auto& dict = renderData.getDictionary();
    if (dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None) != RenderPassRefreshFlags::None)
        return true;
    const auto sceneUpdates = mpScene->getUpdates();
    if ((sceneUpdates & ~IScene::UpdateFlags::CameraPropertiesChanged) != IScene::UpdateFlags::None)
        return true;
    if (is_set(sceneUpdates, IScene::UpdateFlags::CameraPropertiesChanged))
    {
        const auto excluded = Camera::Changes::Jitter | Camera::Changes::History;
        if ((mpScene->getCamera()->getChanges() & ~excluded) != Camera::Changes::None)
            return true;
    }
    return false;
}

void DopplerHistogramPathTracerInline::renderUI(Gui::Widgets& widget)
{
    Options options = mOptions;
    bool dirty = false;

    if (auto group = widget.group("Doppler spectrum", true))
    {
        dirty |= group.var("Wavelength (nm)", options.wavelength, 1.f, 100000.f);
        group.tooltip("Laser wavelength. The Doppler shift of a path is its path velocity / wavelength.", true);
        dirty |= group.var("Chirp bandwidth (GHz)", options.chirpBandwidth, 0.f, 1000.f);
        group.tooltip("FMCW: the laser frequency sweeps by this much over the chirp duration, up and then down. A "
                      "path's beat frequency is f_R - f_D on the up-chirp and f_R + f_D on the down-chirp, with the "
                      "range term f_R = B / T * path length / c. 0: a single-frequency laser.", true);
        if (options.chirped())
        {
            dirty |= group.var("Chirp duration (us)", options.chirpDuration, 1e-3f, 1e6f);
            group.text(fmt::format("Range term: {:.4f} MHz per meter of path length", options.rangeFrequencyPerLength()));
        }
        dirty |= group.var("Frequency min (MHz)", options.frequencyMin, -1e6f, 1e6f);
        dirty |= group.var("Frequency max (MHz)", options.frequencyMax, -1e6f, 1e6f);
        group.tooltip("Range of Doppler frequency shifts (or, with a chirp, beat frequencies). Doppler shifts are "
                      "positive when approaching (the path shortens).", true);
        dirty |= group.var("Bins", options.frequencyBin, 1u, 4096u);
        group.text(fmt::format("Bin width: {:.4f} MHz", options.binWidth()));
        dirty |= group.var("Sensor velocity (m/s)", options.sensorVelocity, -1e4f, 1e4f);
        dirty |= group.var("Light velocity (m/s)", options.lightVelocity, -1e4f, 1e4f);
        for (const auto& [name, motion] : options.velocities)
            group.text(fmt::format("{}: linear ({}, {}, {}) m/s", name, motion.linear.x, motion.linear.y,
                motion.linear.z));
    }

    if (auto group = widget.group("Sampling", true))
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the light.");

    if (auto group = widget.group("Output", true))
    {
        dirty |= options.pathTracing.renderOutputUI(group, true, true);
        dirty |= group.checkbox("Accumulate", options.accumulate);
        group.tooltip("Sum frames in the spectrum in place, restarting when the camera moves or a setting changes.",
            true);
        if (options.accumulate && group.button("Reset spectrum"))
            resetSpectrum();
    }

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
        // The spectrum texture depends on the bin count and channel count.
        const bool resize = options.frequencyBin != mOptions.frequencyBin ||
                            options.pathTracing.useSingleChannel != mOptions.pathTracing.useSingleChannel ||
                            options.chirped() != mOptions.chirped();
        mOptions = options;
        mOptionsChanged = true;
        resetSpectrum();
        if (resize)
            requestRecompile();
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void DopplerHistogramPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpComputePass = nullptr;
    mFrameCount = 0;
    mVelocitiesDirty = true;
    resetSpectrum();
    mpScene = pScene;
}
