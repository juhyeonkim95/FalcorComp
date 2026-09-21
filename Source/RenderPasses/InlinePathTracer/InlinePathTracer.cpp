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
#include "InlinePathTracer.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, InlinePathTracer>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/InlinePathTracer/InlinePathTracer.cs.slang";
const ChannelList kInputChannels = {
    {"vbuffer", "gVBuffer", "Packed visibility buffer"},
    {"viewW", "gViewW", "World-space view direction", true},
};
const ChannelList kOutputChannels = {
    {"color", "gOutputColor", "Linear radiance", false, ResourceFormat::RGBA32Float},
};
const char kMaxBounces[] = "maxBounces";
const char kSamplesPerPixel[] = "samplesPerPixel";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kUseAlphaTest[] = "useAlphaTest";
} // namespace

InlinePathTracer::InlinePathTracer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
}

void InlinePathTracer::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxBounces) mOptions.maxBounces = value;
        else if (key == kSamplesPerPixel) mOptions.samplesPerPixel = value;
        else if (key == kComputeDirect) mOptions.computeDirect = value;
        else if (key == kUseImportanceSampling) mOptions.useImportanceSampling = value;
        else if (key == kUseAlphaTest) mOptions.useAlphaTest = value;
        else FALCOR_THROW("Unknown InlinePathTracer property '{}'.", key);
    }
    if (mOptions.samplesPerPixel == 0)
        FALCOR_THROW("samplesPerPixel must be greater than zero.");
}

Properties InlinePathTracer::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mOptions.maxBounces;
    props[kSamplesPerPixel] = mOptions.samplesPerPixel;
    props[kComputeDirect] = mOptions.computeDirect;
    props[kUseImportanceSampling] = mOptions.useImportanceSampling;
    props[kUseAlphaTest] = mOptions.useAlphaTest;
    return props;
}

RenderPassReflection InlinePathTracer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflection;
    addRenderPassInputs(reflection, kInputChannels);
    addRenderPassOutputs(reflection, kOutputChannels);
    return reflection;
}

DefineList InlinePathTracer::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines;
    defines.add("MAX_BOUNCES", std::to_string(mOptions.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.computeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.useImportanceSampling ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.useAlphaTest ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    return defines;
}

void InlinePathTracer::prepareProgram(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mpComputePass) return;

    ProgramDesc desc;
    desc.addShaderModules(mpScene->getShaderModules());
    desc.addShaderLibrary(kShaderFile).csEntry("main");
    desc.addTypeConformances(mpScene->getTypeConformances());
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    defines.add(getShaderDefines(renderData));
    mpComputePass = ComputePass::create(mpDevice, desc, defines, true);
}

void InlinePathTracer::bindShaderData(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto var = mpComputePass->getRootVar();
    mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    mpSampleGenerator->bindShaderData(var);
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gSamplesPerPixel"] = mOptions.samplesPerPixel;
    const auto& dict = renderData.getDictionary();
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    for (const auto& channel : kInputChannels)
        var[channel.texname] = renderData.getTexture(channel.name);
    for (const auto& channel : kOutputChannels)
        var[channel.texname] = renderData.getTexture(channel.name);
}

void InlinePathTracer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        auto& dict = renderData.getDictionary();
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[kRenderPassRefreshFlags] = flags | RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }
    if (!mpScene)
    {
        pRenderContext->clearTexture(renderData.getTexture("color").get());
        return;
    }
    if (is_set(mpScene->getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(mpScene->getUpdates(), IScene::UpdateFlags::GeometryChanged))
        FALCOR_THROW("InlinePathTracer does not support scene changes requiring shader recompilation.");

    if (mpScene->getCamera()->getApertureRadius() > 0.f && !renderData.getTexture("viewW"))
        logWarning("InlinePathTracer: depth of field requires the 'viewW' input.");

    // Scene::useEmissiveLights() requires the light collection to exist.
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    prepareProgram(pRenderContext, renderData);
    mpComputePass->getProgram()->addDefines(getShaderDefines(renderData));
    bindShaderData(pRenderContext, renderData);
    mpComputePass->execute(pRenderContext, uint3(renderData.getDefaultTextureDims(), 1));
    ++mFrameCount;
}

void InlinePathTracer::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    dirty |= widget.var("Samples per pixel", mOptions.samplesPerPixel, 1u, 1024u);
    dirty |= widget.var("Max indirect bounces", mOptions.maxBounces, 0u, 1u << 16);
    widget.tooltip("Zero evaluates direct lighting only.");
    dirty |= widget.checkbox("Evaluate direct illumination", mOptions.computeDirect);
    dirty |= widget.checkbox("Use importance sampling", mOptions.useImportanceSampling);
    dirty |= widget.checkbox("Use alpha test", mOptions.useAlphaTest);
    mOptionsChanged |= dirty;
}

void InlinePathTracer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpComputePass = nullptr;
    mpScene = pScene;
    mFrameCount = 0;
    mOptionsChanged = true;
}
