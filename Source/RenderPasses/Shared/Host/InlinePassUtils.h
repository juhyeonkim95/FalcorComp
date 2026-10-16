#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Utils/Sampling/SampleGenerator.h"
#include <string>

using namespace Falcor;

/** Helpers shared by the inline ray tracing render passes: the ToF path tracers and ReSTIR passes (time-gated,
 * transient histogram, CW-ToF) and the structured-light path tracer.
 */
namespace InlinePass
{
/// Names of the optional inputs from VBufferRT.
inline constexpr char kViewDirChannel[] = "viewW";
inline constexpr char kMotionVectorChannel[] = "mvec";

/// Inputs of the passes whose camera paths start at the primary hits from VBufferRT.
inline const ChannelList kPrimaryHitInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kViewDirChannel,  "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
    // clang-format on
};

/// The same, with the motion vectors that temporal reuse reprojects the history with.
inline const ChannelList kPrimaryHitAndMotionInputChannels = {
    // clang-format off
    { "vbuffer",            "gVBuffer",         "Visibility buffer in packed format" },
    { kMotionVectorChannel, "gMotionVector",    "Motion vector buffer (float format)", true /* optional */ },
    { kViewDirChannel,      "gViewW",           "World-space view direction (xyz float format)", true /* optional */ },
    // clang-format on
};

/// The radiance output of the path tracers and ReSTIR passes.
inline const ChannelList kColorOutputChannels = {
    // clang-format off
    { "color",          "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

/// Compute pass for the "main" entry of `shaderFile`, with the scene's shader modules, type conformances and
/// defines, the sample generator's defines and `defines`. Binds the scene and the sample generator.
inline ref<ComputePass> createScenePass(
    ref<Device> pDevice,
    RenderContext* pRenderContext,
    const ref<Scene>& pScene,
    const ref<SampleGenerator>& pSampleGenerator,
    const std::string& shaderFile,
    const DefineList& defines
)
{
    ProgramDesc desc;
    desc.addShaderModules(pScene->getShaderModules());
    desc.addShaderLibrary(shaderFile).csEntry("main");
    desc.addTypeConformances(pScene->getTypeConformances());

    DefineList allDefines;
    allDefines.add(pScene->getSceneDefines());
    allDefines.add(pSampleGenerator->getDefines());
    allDefines.add(defines);
    ref<ComputePass> pPass = ComputePass::create(pDevice, desc, allDefines, true);

    ShaderVar var = pPass->getRootVar();
    pScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    pSampleGenerator->bindShaderData(var);
    return pPass;
}

/// Applies `defines` to a pass made by createScenePass(). When they change, the program is recompiled with a new
/// layout (e.g. a resource that only exists under a define), so the pass's vars are recreated and the scene and the
/// sample generator bound again; bind everything else after this call.
inline void updateScenePassDefines(
    RenderContext* pRenderContext,
    const ref<ComputePass>& pPass,
    const ref<Scene>& pScene,
    const ref<SampleGenerator>& pSampleGenerator,
    const DefineList& defines
)
{
    if (!pPass->getProgram()->addDefines(defines))
        return;
    pPass->setVars(nullptr);
    ShaderVar var = pPass->getRootVar();
    pScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    pSampleGenerator->bindShaderData(var);
}

/// Which kinds of scene lights are in use (USE_ANALYTIC_LIGHTS, USE_EMISSIVE_LIGHTS, USE_ENV_LIGHT,
/// USE_ENV_BACKGROUND).
inline DefineList getSceneLightDefines(const Scene& scene)
{
    DefineList defines;
    defines.add("USE_ANALYTIC_LIGHTS", scene.useAnalyticLights() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", scene.useEmissiveLights() ? "1" : "0");
    defines.add("USE_ENV_LIGHT", scene.useEnvLight() ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", scene.useEnvBackground() ? "1" : "0");
    return defines;
}

/// Binds each channel's texture to the channel's shader variable under `var`.
inline void bindChannels(const ShaderVar& var, const RenderData& renderData, const ChannelList& channels)
{
    for (const auto& channel : channels)
        if (!channel.texname.empty())
            var[channel.texname] = renderData.getTexture(channel.name);
}

/// Clears the channels' textures that are connected to zero, alpha included (a histogram's alpha sums sample weights).
inline void clearChannels(RenderContext* pRenderContext, const RenderData& renderData, const ChannelList& channels)
{
    for (const auto& channel : channels)
        if (auto pTexture = renderData.getTexture(channel.name))
            pRenderContext->clearTexture(pTexture.get(), float4(0.f));
}

/// Zeroes textures, including 3D textures deeper than 1024 slices. gfx's UAV clear on Vulkan leaves the depth slices
/// from 1024 on untouched, so a 3D output that is cleared every frame and then added to would keep accumulating
/// there. 3D 32-bit float textures with 1, 2 or 4 channels are therefore cleared by a compute shader; everything
/// else goes through RenderContext::clearTexture().
class Texture3DClearer
{
public:
    void clear(RenderContext* pRenderContext, const ref<Texture>& pTexture)
    {
        if (!pTexture)
            return;
        const ResourceFormat format = pTexture->getFormat();
        const uint32_t channels = getFormatChannelCount(format);
        const bool float32 = getFormatType(format) == FormatType::Float && getNumChannelBits(format, 0) == 32;
        if (pTexture->getType() != Resource::Type::Texture3D || !float32 || channels == 3)
        {
            pRenderContext->clearTexture(pTexture.get(), float4(0.f));
            return;
        }
        ref<ComputePass>& pPass = mPasses[channels];
        if (!pPass)
        {
            DefineList defines;
            defines.add("CHANNELS", std::to_string(channels));
            pPass = ComputePass::create(pTexture->getDevice(), "RenderPasses/Shared/Shaders/Utils/ClearTexture3D.cs.slang", "main", defines);
        }
        const uint3 size(pTexture->getWidth(), pTexture->getHeight(), pTexture->getDepth());
        ShaderVar var = pPass->getRootVar();
        var["gTexture"] = pTexture;
        var["CB"]["gSize"] = size;
        pPass->execute(pRenderContext, size);
    }

private:
    ref<ComputePass> mPasses[5]; ///< By channel count.
};


/// clearChannels for outputs that may be 3D textures deeper than 1024 slices: those are zeroed by `clearer`.
inline void clearChannels(RenderContext* pRenderContext, const RenderData& renderData, const ChannelList& channels,
    Texture3DClearer& clearer)
{
    for (const auto& channel : channels)
        if (auto pTexture = renderData.getTexture(channel.name))
            clearer.clear(pRenderContext, pTexture);
}

/// setProperties() of a pass with validated options: `parse` reads the properties into `options`; when it or `validate`
/// throws (an unknown enum name, an invalid value), the previous options are restored.
template<typename Options, typename Parse, typename Validate>
void applyProperties(Options& options, Parse&& parse, Validate&& validate)
{
    const Options previous = options;
    try
    {
        parse();
        validate(options);
    }
    catch (...)
    {
        options = previous;
        throw;
    }
}

/// Tells downstream passes (e.g. accumulation) that this pass's output changed.
inline void flagOptionsChanged(const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();
    auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
    dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
}

/// Throws on scene changes that need shader recompilation, and warns when depth of field is used without the
/// view direction input.
inline void checkScene(const Scene& scene, const RenderData& renderData)
{
    if (is_set(scene.getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(scene.getUpdates(), IScene::UpdateFlags::GeometryChanged))
        FALCOR_THROW("This render pass does not support scene changes that require shader recompilation.");
    // The passes dispatch over their output and read the V-buffer at the same pixel.
    const auto pVBuffer = renderData.getTexture("vbuffer");
    const auto pColor = renderData.getTexture("color");
    if (pVBuffer && pColor && (pVBuffer->getWidth() != pColor->getWidth() || pVBuffer->getHeight() != pColor->getHeight()))
        FALCOR_THROW("The vbuffer input ({}x{}) must have the output's size ({}x{}): set the same outputSize on VBufferRT.",
            pVBuffer->getWidth(), pVBuffer->getHeight(), pColor->getWidth(), pColor->getHeight());
    if (scene.getCamera()->getApertureRadius() > 0.f && renderData[kViewDirChannel] == nullptr)
        logWarningOnce("Depth-of-field requires the '{}' input. Expect incorrect shading.", kViewDirChannel);
}
} // namespace InlinePass
