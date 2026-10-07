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
    mGate.advance();
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
    options.ellipsoidalSampling.validate();
}

void TimeGatedPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.timeGate.parse(key, value) || mOptions.ellipsoidalSampling.parse(key, value) || mOptions.pathTracing.parse(key, value))
            continue;
        logWarning("Unknown property '{}' in TimeGatedPathTracerInline properties.", key);
    }
    mOptions.timeGate.applyTimeCenter(props);
}

void TimeGatedPathTracerInline::onOptionsChanged(const Options& previous)
{
    // The triangle sampler follows the options in prepare(), and its defines are part of getShaderDefines().
    mOptionsChanged = true;
}

void TimeGatedPathTracerInline::setProperties(const Properties& props)
{
    const Options previous = mOptions;
    // Invalid properties throw and leave the options unchanged.
    InlinePass::applyProperties(mOptions, [&] { parseProperties(props); }, validateOptions);
    onOptionsChanged(previous);
}

Properties TimeGatedPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.timeGate.serialize(props);
    mOptions.ellipsoidalSampling.serialize(props);
    mOptions.pathTracing.serialize(props);
    return props;
}

RenderPassReflection TimeGatedPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitInputChannels);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels);

    return reflector;
}

DefineList TimeGatedPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(mLaserInput.get().getDefines());
    defines.add(InlinePass::getSceneLightDefines(*mpScene));

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.ellipsoidalSampling.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)EllipsoidalSamplingMethod::Direct));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)EllipsoidalSamplingMethod::Ellipsoidal));
    defines.add("ELLIPSOIDAL_DIRECT_MIS", std::to_string((uint32_t)EllipsoidalSamplingMethod::EllipsoidalDirectMIS));
    defines.add(mTriangleSampler.getDefines());

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    return defines;
}

void TimeGatedPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    mTriangleSampler.bindShaderData(var);

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gEllipsoidRoughnessThreshold"] = mOptions.ellipsoidalSampling.ellipsoidRoughnessThreshold;
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    mLaserInput.get().bindShaderData(var["Laser"]);
    mOptions.timeGate.bindShaderData(var["TimeGate"], mGate);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
}

void TimeGatedPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    mLaserInput.update(renderData, "TimeGatedPathTracerInline");
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

    mOptions.timeGate.beginFrame(mGate);
    mTriangleSampler.prepare(pRenderContext, mpScene, mOptions.ellipsoidalSampling);
    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile,
            getShaderDefines(renderData));
    InlinePass::checkScene(*mpScene, renderData);
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator, getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    mpComputePass->execute(pRenderContext, uint3(renderData.getDefaultTextureDims(), 1));

    mFrameCount++;
    mGate.endFrame();
    if (mOptions.timeGate.shiftGate && mOptions.timeGate.timeMax > mOptions.timeGate.timeMin)
        incrementTimeGateFrame();
}

void TimeGatedPathTracerInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    auto options = mOptions;

    if (auto group = widget.group("Time gate", true))
        dirty |= options.timeGate.renderUI(group, mGate.current);

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the laser spot.");
        dirty |= options.ellipsoidalSampling.renderUI(group);
    }

    if (auto group = widget.group("Output", true))
        dirty |= options.pathTracing.renderOutputUI(group, true, true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
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
        const Options previous = mOptions;
        mOptions = options;
        onOptionsChanged(previous);
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void TimeGatedPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should be recreated.
    mpComputePass = nullptr;
    mTriangleSampler.reset();
    mFrameCount = 0;
    mOptionsChanged = true;
    // Preserve the scripted gate index when replacing the scene.

    // Set new scene.
    mpScene = pScene;
}
