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
#include "CWToFPathTracerInline.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, CWToFPathTracerInline>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/CWToFPathTracerInline/CWToFPathTracerInline.cs.slang";
const char kUseAntitheticSampling[] = "useAntitheticSampling";
const char kAntitheticRoundTripCheck[] = "antitheticRoundTripCheck";

} // namespace

CWToFPathTracerInline::CWToFPathTracerInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    // Defaults that differ from the shared configs': the primary-hit term carries most of the signal, and the
    // antithetic shift needs a shift mapping with inverse forward and backward shifts.
    mOptions.pathTracing.computeDirect = true;
    mOptions.shiftMapping.shiftmapMethod = ShiftMappingMethod::RADIAL;
    mOptions.shiftMapping.gaugeMode = GaugeMode::ORTHO_AVG_GRAD;
    mOptions.shiftMapping.newtonRelativeTolerance = 0.002f;

    parseProperties(props);
    validateOptions(mOptions);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void CWToFPathTracerInline::validateOptions(const Options& options)
{
    options.continuousWave.validate();
    options.pathTracing.validate();
}

void CWToFPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.continuousWave.parse(key, value) || mOptions.pathTracing.parse(key, value) ||
            mOptions.shiftMapping.parse(key, value))
            continue;
        if (key == kUseAntitheticSampling)
            mOptions.useAntitheticSampling = value;
        else if (key == kAntitheticRoundTripCheck)
            mOptions.antitheticRoundTripCheck = value;
        else
            logWarning("Unknown property '{}' in CWToFPathTracerInline properties.", key);
    }
}

Properties CWToFPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.continuousWave.serialize(props);
    mOptions.pathTracing.serialize(props);
    mOptions.shiftMapping.serialize(props);
    props[kUseAntitheticSampling] = mOptions.useAntitheticSampling;
    props[kAntitheticRoundTripCheck] = mOptions.antitheticRoundTripCheck;
    return props;
}

void CWToFPathTracerInline::setProperties(const Properties& props)
{
    InlinePass::applyProperties(mOptions, [&] { parseProperties(props); }, validateOptions);
    mOptionsChanged = true;
}

RenderPassReflection CWToFPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitInputChannels);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels);

    return reflector;
}

DefineList CWToFPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(LaserState::resolve(renderData).getDefines());
    defines.add(InlinePass::getSceneLightDefines(*mpScene));
    defines.add(mOptions.shiftMapping.getDefines());
    defines.add("USE_ANTITHETIC_SAMPLING", mOptions.useAntitheticSampling ? "1" : "0");
    defines.add("ANTITHETIC_ROUND_TRIP_CHECK", mOptions.antitheticRoundTripCheck ? "1" : "0");

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    return defines;
}

void CWToFPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    LaserState::resolve(renderData).bindShaderData(var["Laser"]);
    mOptions.continuousWave.bindShaderData(var["ContinuousWave"]);
    mOptions.shiftMapping.bindShaderData(var["ShiftMappingCB"]);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
}

void CWToFPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
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

    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, getShaderDefines(renderData));
    InlinePass::checkScene(*mpScene, renderData);
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator, getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    mpComputePass->execute(pRenderContext, uint3(renderData.getDefaultTextureDims(), 1));

    mFrameCount++;
}

void CWToFPathTracerInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    auto options = mOptions;

    if (auto group = widget.group("Modulation", true))
        dirty |= options.continuousWave.renderUI(group);

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the laser spot.");
        dirty |= group.checkbox("Antithetic sampling", options.useAntitheticSampling);
        group.tooltip("Pair each BSDF-sampled vertex with a copy moved on its surface so the waveform has the "
                      "opposite sign (half a wavelength longer or shorter; the sawtooth's mirror image), and combine "
                      "the two with MIS.", true);
    }

    if (options.useAntitheticSampling)
    {
        if (auto group = widget.group("Antithetic shift mapping", true))
        {
            dirty |= group.checkbox("Round-trip check", options.antitheticRoundTripCheck);
            group.tooltip("Keep a shift only if shifting the partner back returns to the start, so the forward and "
                          "backward shifts are exact inverses. Costs a second Newton solve.", true);
            dirty |= options.shiftMapping.renderUI(group,
                "How the antithetic vertex is found: it is moved on its surface so the path length changes by the "
                "antithetic offset.\nRadial (the default): along the ray from the path length's minimum on the "
                "vertex's plane; the forward and backward shifts are exact inverses.\nThe other methods use a Newton "
                "solve on their chart, whose forward and backward shifts can disagree near the minimum (use the "
                "round-trip check).\nNone pairs the vertex with itself (no variance reduction).");
        }
    }

    if (auto group = widget.group("Output", true))
        dirty |= options.pathTracing.renderOutputUI(group, true, true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        validateOptions(options);
        mOptions = options;
        mOptionsChanged = true;
    }
}

void CWToFPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;
    mOptionsChanged = true;

    // Set new scene.
    mpScene = pScene;
}
