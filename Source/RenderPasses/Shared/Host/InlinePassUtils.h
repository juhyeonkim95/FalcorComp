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

/// Clears the channels' textures that are connected.
inline void clearChannels(RenderContext* pRenderContext, const RenderData& renderData, const ChannelList& channels)
{
    for (const auto& channel : channels)
        if (auto pTexture = renderData.getTexture(channel.name))
            pRenderContext->clearTexture(pTexture.get());
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
inline void checkScene(const Scene& scene, const RenderData& renderData, const char* viewDirChannel)
{
    if (is_set(scene.getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(scene.getUpdates(), IScene::UpdateFlags::GeometryChanged))
        FALCOR_THROW("This render pass does not support scene changes that require shader recompilation.");
    if (scene.getCamera()->getApertureRadius() > 0.f && renderData[viewDirChannel] == nullptr)
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", viewDirChannel);
}
} // namespace InlinePass
