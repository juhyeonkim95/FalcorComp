#pragma once
#include "Falcor.h"
#include "Scene/Lights/LightCollection.h"
#include "Scene/Scene.h"

using namespace Falcor;

/// Every triangle of the scene, as a light collection weighted by area instead of emitted flux (LightCollection with
/// allTriangles): the triangles that hold the vertex y of ellipsoidal connections, and those of THPT's single-bounce
/// approximation. Triangles larger than an area cutoff (world space) are left out, e.g. an NLOS relay wall. The shaders
/// read it as gSceneTriangles (Shared/Shaders/Lights/SceneTriangles.slang). It is built once for a scene and cutoff:
/// animated geometry is not followed unless the owner calls update() on it.
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
