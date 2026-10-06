#pragma once
#include "ConfigUtils.h"
#include "../SceneTriangles.h"
#include "Rendering/Lights/EmissiveLightSamplerType.slangh"
#include "Rendering/Lights/LightBVH.h"
#include "Rendering/Lights/LightBVHBuilder.h"
#include "Scene/Scene.h"
#include <memory>

/// How a camera-path vertex x is connected to the laser spot: directly, through a vertex y placed on the
/// ellipsoid of paths x -> y -> laser spot that fit the gate, or both combined with MIS.
enum class EllipsoidalSamplingMethod
{
    Direct = 0,
    Ellipsoidal = 1,
    EllipsoidalDirectMIS = 2,
};

inline const std::unordered_map<std::string, EllipsoidalSamplingMethod> kEllipsoidalSamplingMethods = {
    {"direct", EllipsoidalSamplingMethod::Direct},
    {"ellipsoidal", EllipsoidalSamplingMethod::Ellipsoidal},
    {"ellipsoidal_direct_mis", EllipsoidalSamplingMethod::EllipsoidalDirectMIS},
};

struct EllipsoidalSamplingConfig
{
    EllipsoidalSamplingMethod samplingMethod = EllipsoidalSamplingMethod::Direct;
    EmissiveLightSamplerType triSampler = EmissiveLightSamplerType::LightBVH; ///< Picks the triangle of an ellipsoidal connection.
    float ellipsoidRoughnessThreshold = 0.25f; ///< ELLIPSOIDAL only: minimum roughness for an ellipsoidal connection.
    /// Triangles larger than this (world-space area) never hold an ellipsoidal vertex, e.g. an NLOS relay wall that
    /// would take most samples; paths through them come from the BSDF technique.
    float maxTriangleArea = 10000.f;

    bool usesEllipsoid() const { return samplingMethod != EllipsoidalSamplingMethod::Direct; }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "samplingMethod")
            samplingMethod = parseEnumProperty(kEllipsoidalSamplingMethods, value, key);
        else if (key == "emissiveSampler")
            triSampler = value;
        else if (key == "specularRoughnessThresholdEllipsoid")
            ellipsoidRoughnessThreshold = value;
        else if (key == "ellipsoidMaxTriangleArea")
            maxTriangleArea = value;
        else
            return false;
        return true;
    }

    /// The triangle sampler must implement the ellipsoid queries: Uniform or LightBVH.
    void validate() const
    {
        if (usesEllipsoid() && triSampler != EmissiveLightSamplerType::Uniform && triSampler != EmissiveLightSamplerType::LightBVH)
            FALCOR_THROW("emissiveSampler must be Uniform or LightBVH for ellipsoidal sampling.");
        if (!(maxTriangleArea > 0.f))
            FALCOR_THROW("ellipsoidMaxTriangleArea must be greater than zero.");
    }

    void serialize(Properties& props) const
    {
        props["samplingMethod"] = enumPropertyName(kEllipsoidalSamplingMethods, samplingMethod);
        props["emissiveSampler"] = triSampler;
        props["specularRoughnessThresholdEllipsoid"] = ellipsoidRoughnessThreshold;
        props["ellipsoidMaxTriangleArea"] = maxTriangleArea;
    }

    /// Sampling method, and the ellipsoid threshold and triangle sampler when they apply.
    bool renderUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        static const Gui::DropdownList kSamplingMethodList = {
            {(uint32_t)EllipsoidalSamplingMethod::Direct, "Direct"},
            {(uint32_t)EllipsoidalSamplingMethod::Ellipsoidal, "Ellipsoidal"},
            {(uint32_t)EllipsoidalSamplingMethod::EllipsoidalDirectMIS, "Ellipsoidal + direct (MIS)"},
        };
        uint32_t method = (uint32_t)samplingMethod;
        if (widget.dropdown("Sampling method", kSamplingMethodList, method))
        {
            samplingMethod = (EllipsoidalSamplingMethod)method;
            dirty = true;
        }
        widget.tooltip("How a camera-path vertex x is connected to the laser spot:\n"
                       "Direct: connect x -> laser spot.\n"
                       "Ellipsoidal: insert a vertex y on the ellipsoid of paths x -> y -> laser spot whose length "
                       "matches the gate.\n"
                       "Ellipsoidal + direct (MIS): both, combined with the balance heuristic.", true);

        if (samplingMethod == EllipsoidalSamplingMethod::Ellipsoidal)
        {
            dirty |= widget.var("Ellipsoid roughness threshold", ellipsoidRoughnessThreshold, 0.f, 1.f);
            widget.tooltip("Use an ellipsoidal connection at x only if its roughness is above this value; smoother "
                           "vertices use a direct connection from the next vertex instead.", true);
        }

        if (usesEllipsoid())
        {
            static const Gui::DropdownList kSamplerList = {
                {(uint32_t)EmissiveLightSamplerType::Uniform, "Uniform"},
                {(uint32_t)EmissiveLightSamplerType::LightBVH, "LightBVH"},
            };
            uint32_t sampler = (uint32_t)triSampler;
            if (widget.dropdown("Ellipsoid triangle sampler", kSamplerList, sampler))
            {
                triSampler = (EmissiveLightSamplerType)sampler;
                dirty = true;
            }
            widget.tooltip("How an ellipsoidal connection selects the scene triangle on which it places y.", true);
            dirty |= widget.var("Ellipsoid max triangle area", maxTriangleArea, 1e-6f, 1e12f);
            widget.tooltip("Triangles larger than this (world-space area) never hold y, e.g. an NLOS relay wall that "
                           "would take most samples. Paths through them come from BSDF sampling.", true);
        }
        return dirty;
    }
};

/// Runtime part of EllipsoidalSamplingConfig: the scene triangles that hold the vertex y of an ellipsoidal connection
/// (SceneTriangles) and, for the LightBVH method, a light BVH over them with one triangle per leaf. The shaders pick a
/// triangle with Shared/Shaders/Lights/EllipsoidTriangleSampler.slang. It is kept out of the config so that the config
/// stays copyable.
class EllipsoidalTriangleSampler
{
public:
    /// Builds the triangles, and the BVH for LightBVH, once `config` uses the ellipsoid; rebuilds them when the area
    /// cutoff changes. Call reset() after changing the scene.
    void prepare(RenderContext* pRenderContext, const ref<Scene>& pScene, const EllipsoidalSamplingConfig& config)
    {
        if (!config.usesEllipsoid() && mTriangles.empty())
            return;
        const ref<LightCollection>& pTriangles = mTriangles.get(pRenderContext, pScene, config.maxTriangleArea);
        if (pTriangles != mpBVHTriangles)
        {
            FALCOR_CHECK(pTriangles->getActiveLightCount(pRenderContext) > 0,
                "Ellipsoidal sampling found no scene triangles (all larger than ellipsoidMaxTriangleArea?).");
            mpBVH.reset();
            mpBVHTriangles = pTriangles;
        }
        mUseBVH = config.triSampler == EmissiveLightSamplerType::LightBVH;
        if (mUseBVH && !mpBVH)
        {
            LightBVHBuilder::Options options;
            options.maxTriangleCountPerLeaf = 1;
            mpBVH = std::make_unique<LightBVH>(pScene->getDevice(), pTriangles);
            LightBVHBuilder(options).build(pRenderContext, *mpBVH);
        }
    }

    void reset()
    {
        mTriangles.reset();
        mpBVH.reset();
        mpBVHTriangles = nullptr;
    }

    /// ELLIPSOID_TRIANGLE_SAMPLER, once prepared; empty before.
    DefineList getDefines() const
    {
        DefineList defines;
        if (!mTriangles.empty())
            defines.add("ELLIPSOID_TRIANGLE_SAMPLER", mUseBVH ? "1" : "0");
        return defines;
    }

    /// Binds gSceneTriangles and gSceneTriangleBVH under `var` (the root).
    void bindShaderData(const ShaderVar& var) const
    {
        mTriangles.bindShaderData(var);
        if (mUseBVH && mpBVH)
            mpBVH->bindShaderData(var["gSceneTriangleBVH"]);
    }

private:
    SceneTriangles mTriangles;
    std::unique_ptr<LightBVH> mpBVH;
    ref<LightCollection> mpBVHTriangles; ///< The triangles mpBVH was built over.
    bool mUseBVH = true;
};
