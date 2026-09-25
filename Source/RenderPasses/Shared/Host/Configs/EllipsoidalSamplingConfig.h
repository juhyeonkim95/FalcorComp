#pragma once
#include "ConfigUtils.h"
#include "Rendering/Lights/EmissiveLightSamplerType.slangh"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EmissiveUniformSampler.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Scene/Scene.h"
#include <memory>

/// How a camera-path vertex x is connected to the laser spot: directly, through a vertex y placed on the
/// ellipsoid of paths x -> y -> laser spot that fit the gate, or both combined with MIS.
enum class EllipsoidalSamplingMethod
{
    DIRECT = 0,
    ELLIPSOIDAL = 1,
    ELLIPSOIDAL_DIRECT_MIS = 2,
};

inline const std::unordered_map<std::string, EllipsoidalSamplingMethod> kEllipsoidalSamplingMethods = {
    {"direct", EllipsoidalSamplingMethod::DIRECT},
    {"ellipsoidal", EllipsoidalSamplingMethod::ELLIPSOIDAL},
    {"ellipsoidal_direct_mis", EllipsoidalSamplingMethod::ELLIPSOIDAL_DIRECT_MIS},
};

struct EllipsoidalSamplingConfig
{
    EllipsoidalSamplingMethod samplingMethod = EllipsoidalSamplingMethod::DIRECT;
    EmissiveLightSamplerType triSampler = EmissiveLightSamplerType::LightBVH; ///< Picks the triangle of an ellipsoidal connection.
    float ellipsoidRoughnessThreshold = 0.25f; ///< ELLIPSOIDAL only: minimum roughness for an ellipsoidal connection.

    bool usesEllipsoid() const { return samplingMethod != EllipsoidalSamplingMethod::DIRECT; }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "samplingMethod")
            samplingMethod = parseEnumProperty(kEllipsoidalSamplingMethods, value, key);
        else if (key == "emissiveSampler")
            triSampler = value;
        else if (key == "specularRoughnessThresholdEllipsoid")
            ellipsoidRoughnessThreshold = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["samplingMethod"] = enumPropertyName(kEllipsoidalSamplingMethods, samplingMethod);
        props["emissiveSampler"] = triSampler;
        props["specularRoughnessThresholdEllipsoid"] = ellipsoidRoughnessThreshold;
    }

    /// Sampling method, and the ellipsoid threshold and triangle sampler when they apply.
    bool renderUI(Gui::Widgets& widget, bool allowPowerSampler)
    {
        bool dirty = false;
        static const Gui::DropdownList kSamplingMethodList = {
            {(uint32_t)EllipsoidalSamplingMethod::DIRECT, "Direct"},
            {(uint32_t)EllipsoidalSamplingMethod::ELLIPSOIDAL, "Ellipsoidal"},
            {(uint32_t)EllipsoidalSamplingMethod::ELLIPSOIDAL_DIRECT_MIS, "Ellipsoidal + direct (MIS)"},
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

        if (samplingMethod == EllipsoidalSamplingMethod::ELLIPSOIDAL)
        {
            dirty |= widget.var("Ellipsoid roughness threshold", ellipsoidRoughnessThreshold, 0.f, 1.f);
            widget.tooltip("Use an ellipsoidal connection at x only if its roughness is above this value; smoother "
                           "vertices use a direct connection from the next vertex instead.", true);
        }

        if (usesEllipsoid())
        {
            Gui::DropdownList samplers = {
                {(uint32_t)EmissiveLightSamplerType::Uniform, "Uniform"},
                {(uint32_t)EmissiveLightSamplerType::LightBVH, "LightBVH"},
            };
            if (allowPowerSampler)
                samplers.push_back({(uint32_t)EmissiveLightSamplerType::Power, "Power"});
            uint32_t sampler = (uint32_t)triSampler;
            if (widget.dropdown("Ellipsoid triangle sampler", samplers, sampler))
            {
                triSampler = (EmissiveLightSamplerType)sampler;
                dirty = true;
            }
            widget.tooltip("How an ellipsoidal connection selects the scene triangle on which it places y.", true);
        }
        return dirty;
    }
};

/// Runtime part of EllipsoidalSamplingConfig: the sampler that picks the scene triangle of an ellipsoidal
/// connection. It is kept out of the config so that the config stays copyable.
class EllipsoidalTriangleSampler
{
public:
    /// Creates the sampler once `config` uses the ellipsoid, and requests the scene's triangle collection each
    /// frame while it exists. Call reset() after changing the scene or the config's triSampler.
    void prepare(RenderContext* pRenderContext, const ref<Scene>& pScene, const EllipsoidalSamplingConfig& config)
    {
        if (!mpSampler && config.usesEllipsoid())
        {
            const auto& pTriangles = pScene->getITriCollection(pRenderContext);
            FALCOR_ASSERT(pTriangles && pTriangles->getActiveLightCount(pRenderContext) > 0);
            mLightBVHOptions.buildOptions.maxTriangleCountPerLeaf = 1;
            switch (config.triSampler)
            {
            case EmissiveLightSamplerType::Uniform:
                mpSampler = std::make_unique<EmissiveUniformSampler>(pRenderContext, pTriangles);
                break;
            case EmissiveLightSamplerType::LightBVH:
                mpSampler = std::make_unique<LightBVHSampler>(pRenderContext, pTriangles, mLightBVHOptions);
                break;
            case EmissiveLightSamplerType::Power:
                mpSampler = std::make_unique<EmissivePowerSampler>(pRenderContext, pTriangles);
                break;
            default:
                FALCOR_THROW("Unknown emissive light sampler type");
            }
            mpSampler->update(pRenderContext, pTriangles);
        }
        if (mpSampler)
            pScene->getTriCollection(pRenderContext);
    }

    void reset() { mpSampler.reset(); }

    /// The sampler's shader type defines; empty without a sampler.
    DefineList getDefines() const { return mpSampler ? mpSampler->getDefines() : DefineList(); }

    void bindShaderData(const ShaderVar& var) const
    {
        if (mpSampler)
            mpSampler->bindShaderData(var);
    }

private:
    std::unique_ptr<EmissiveLightSampler> mpSampler;
    LightBVHSampler::Options mLightBVHOptions;
};
