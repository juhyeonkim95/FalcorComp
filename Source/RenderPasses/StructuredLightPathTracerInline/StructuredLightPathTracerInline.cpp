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
#include "StructuredLightPathTracerInline.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regStructuredLightPathTracerInline(pybind11::module& m)
{
    using namespace pybind11::literals;
    pybind11::class_<StructuredLightPathTracerInline, RenderPass, ref<StructuredLightPathTracerInline>> pass(m, "StructuredLightPathTracerInline");
    pass.def("set_pattern_data", &StructuredLightPathTracerInline::setPatternData, "values"_a,
        "antithetic_index"_a = std::vector<uint32_t>(), "interval_ids"_a = std::vector<uint32_t>(),
        "intervals"_a = std::vector<uint32_t>());
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, StructuredLightPathTracerInline>();
    ScriptBindings::registerBinding(regStructuredLightPathTracerInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/StructuredLightPathTracerInline/StructuredLightPathTracerInline.cs.slang";
const char kSamplingMethod[] = "samplingMethod";
const char kProjectorSampleCount[] = "projectorSampleCount";

const std::unordered_map<std::string, StructuredLightSamplingMethod> kSamplingMethods = {
    {"bsdf", StructuredLightSamplingMethod::BSDF},
    {"antithetic", StructuredLightSamplingMethod::Antithetic},
    {"projector", StructuredLightSamplingMethod::Projector},
};

} // namespace

StructuredLightPathTracerInline::StructuredLightPathTracerInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    // The primary-hit term carries most of the pattern, so it is on by default.
    mOptions.pathTracing.computeDirect = true;

    parseProperties(props);
    validateOptions(mOptions);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void StructuredLightPathTracerInline::setPatternData(std::vector<uint32_t> values, std::vector<uint32_t> antitheticIndex,
    std::vector<uint32_t> intervalIds, std::vector<uint32_t> intervals)
{
    mPatternData.set(std::move(values), std::move(antitheticIndex), std::move(intervalIds), std::move(intervals));
    mOptionsChanged = true;
}

void StructuredLightPathTracerInline::validateOptions(const Options& options)
{
    options.projector.validate();
    options.pathTracing.validate();
    if (options.projectorSampleCount == 0)
        FALCOR_THROW("projectorSampleCount must be greater than zero.");
}

void StructuredLightPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.projector.parse(key, value) || mOptions.pathTracing.parse(key, value))
            continue;
        if (key == kSamplingMethod)
            mOptions.samplingMethod = parseEnumProperty(kSamplingMethods, value, key);
        else if (key == kProjectorSampleCount)
            mOptions.projectorSampleCount = value;
        else
            logWarning("Unknown property '{}' in StructuredLightPathTracerInline properties.", key);
    }
}

Properties StructuredLightPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.projector.serialize(props);
    mOptions.pathTracing.serialize(props);
    props[kSamplingMethod] = enumPropertyName(kSamplingMethods, mOptions.samplingMethod);
    props[kProjectorSampleCount] = mOptions.projectorSampleCount;
    return props;
}

void StructuredLightPathTracerInline::setProperties(const Properties& props)
{
    InlinePass::applyProperties(mOptions, [&] { parseProperties(props); }, validateOptions);
    mOptionsChanged = true;
}

RenderPassReflection StructuredLightPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitInputChannels);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels);

    return reflector;
}

DefineList StructuredLightPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(InlinePass::getSceneLightDefines(*mpScene));
    defines.add(mOptions.projector.getDefines());
    defines.add("SAMPLING_METHOD", std::to_string((uint32_t)mOptions.samplingMethod));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    return defines;
}

void StructuredLightPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gProjectorSampleCount"] = mOptions.projectorSampleCount;
    mOptions.projector.bindShaderData(var);
    if (mOptions.projector.pattern == ProjectorPatternType::Arbitrary)
        mPatternData.bindShaderData(mpDevice, var);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
}

void StructuredLightPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

void StructuredLightPathTracerInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    auto options = mOptions;

    if (auto group = widget.group("Projector", true))
        dirty |= options.projector.renderProjectorUI(group);

    if (auto group = widget.group("Pattern", true))
        dirty |= options.projector.renderPatternUI(group);

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the projector.");
        static const Gui::DropdownList kSamplingMethodList = {
            {(uint32_t)StructuredLightSamplingMethod::BSDF, "BSDF"},
            {(uint32_t)StructuredLightSamplingMethod::Antithetic, "BSDF + antithetic"},
            {(uint32_t)StructuredLightSamplingMethod::Projector, "Projector"},
        };
        uint32_t method = (uint32_t)options.samplingMethod;
        if (group.dropdown("Sampling method", kSamplingMethodList, method))
        {
            options.samplingMethod = (StructuredLightSamplingMethod)method;
            dirty = true;
        }
        group.tooltip("How the vertex lit by the projector is reached from the camera path.\n"
                      "BSDF: BSDF sampling, then a connection to the projector.\n"
                      "BSDF + antithetic: each BSDF sample is paired with the point lit through the pattern's "
                      "antithetic uv, where the pattern has the opposite sign, and the two are combined with MIS.\n"
                      "Projector: the vertex is sampled from the projector (stratified along the pattern axis) and "
                      "connected to the camera path.", true);
        if (options.samplingMethod == StructuredLightSamplingMethod::Projector)
        {
            dirty |= group.var("Projector samples", options.projectorSampleCount, 1u, 1024u);
            group.tooltip("Projector samples per camera-path vertex.", true);
        }
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
        mOptions = options;
        mOptionsChanged = true;
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void StructuredLightPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;
    mOptionsChanged = true;

    // Set new scene.
    mpScene = pScene;
}
