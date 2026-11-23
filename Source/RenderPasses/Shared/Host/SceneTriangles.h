#pragma once
#include "Falcor.h"
#include "Scene/Lights/LightCollection.h"
#include "Scene/Scene.h"

using namespace Falcor;

/// Every triangle of the scene, as a light collection weighted by area instead of emitted flux (LightCollection with
/// allTriangles): the triangles that hold the vertex y of ellipsoidal connections, and those of THPT's single-bounce
/// approximation. Triangles larger than an area cutoff (world space) are left out, e.g. an NLOS relay wall. The shaders
/// read it as gSceneTriangles (Shared/Shaders/Lights/SceneTriangles.slang). It is built once for a scene and cutoff;
/// update(), called every frame, moves the triangles of instances whose transform changed. Skinned and vertex-animated
/// meshes are not followed (meshesChanged()).
class SceneTriangles
{
public:
    /// The triangles of `pScene` up to `maxTriangleArea`, built on first use and rebuilt when either changes.
    const ref<LightCollection>& get(RenderContext* pRenderContext, const ref<Scene>& pScene, float maxTriangleArea)
    {
        if (mpTriangles && (mpScene != pScene || mMaxTriangleArea != maxTriangleArea))
            reset();
        if (!mpTriangles)
        {
            mpTriangles = LightCollection::create(pScene->getDevice(), pRenderContext, pScene.get(), true, maxTriangleArea);
            mpScene = pScene;
            mMaxTriangleArea = maxTriangleArea;
        }
        return mpTriangles;
    }

    /// Moves the triangles of the instances that moved this frame (LightCollection::update); returns whether any did.
    /// Call it every frame while the triangles are kept: a frame without it misses that frame's moves.
    bool update(RenderContext* pRenderContext) { return mpTriangles && mpTriangles->update(pRenderContext); }

    /// Skinned or vertex-animated meshes changed this frame; the triangles do not follow them.
    bool meshesChanged() const
    {
        return mpScene && is_set(mpScene->getUpdates(), IScene::UpdateFlags::MeshesChanged);
    }

    void reset()
    {
        mpTriangles = nullptr;
        mpScene = nullptr;
    }

    bool empty() const { return !mpTriangles; }

    /// Binds gSceneTriangles under `var` (the root), once built.
    void bindShaderData(const ShaderVar& var) const
    {
        if (mpTriangles)
            mpTriangles->bindShaderData(var["gSceneTriangles"]);
    }

private:
    ref<Scene> mpScene;
    float mMaxTriangleArea = 0.f;
    ref<LightCollection> mpTriangles;
};
