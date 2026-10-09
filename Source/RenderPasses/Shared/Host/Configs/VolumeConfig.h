#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/Scene.h"
#include "Scene/Material/BasicMaterial.h"

/// Participating media (Shared/Shaders/Volumes/Media.slang): homogeneous media inside closed meshes whose material has
/// volume absorption or scattering. Their surfaces are index-matched: rays cross them unchanged.
struct VolumeConfig
{
    bool useVolumes = false;
    uint maxScatterEvents = 1024; ///< Maximum scattering events in media on a camera path.

    void validate() const
    {
        if (useVolumes && maxScatterEvents == 0)
            FALCOR_THROW("maxScatterEvents must be greater than zero.");
    }

    /// USE_VOLUMES, MAX_SCATTER_EVENTS.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("USE_VOLUMES", useVolumes ? "1" : "0");
        defines.add("MAX_SCATTER_EVENTS", std::to_string(maxScatterEvents));
        return defines;
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "useVolumes")
            useVolumes = value;
        else if (key == "maxScatterEvents")
            maxScatterEvents = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["useVolumes"] = useVolumes;
        props["maxScatterEvents"] = maxScatterEvents;
    }

    bool renderUI(Gui::Widgets& widget)
    {
        bool dirty = widget.checkbox("Participating media", useVolumes);
        widget.tooltip("Render the homogeneous media inside closed meshes whose material has volume absorption or "
                       "scattering. Their surfaces are index-matched: rays cross them unchanged.", true);
        if (useVolumes)
        {
            dirty |= widget.var("Max scatter events", maxScatterEvents, 1u, 1u << 20);
            widget.tooltip("Maximum number of scattering events in media on a camera path.", true);
        }
        return dirty;
    }

    /// Whether a material holds a medium (as isMediumMaterial in Media.slang).
    static bool isMedium(const ref<Material>& pMaterial)
    {
        auto pBasic = dynamic_ref_cast<BasicMaterial>(pMaterial);
        return pBasic && (any(pBasic->getVolumeAbsorption() > 0.f) || any(pBasic->getVolumeScattering() > 0.f));
    }

    static bool hasMedia(const ref<Scene>& pScene)
    {
        if (pScene)
            for (const auto& pMaterial : pScene->getMaterials())
                if (isMedium(pMaterial))
                    return true;
        return false;
    }

    /// Logs the media whose material asks for refraction, which the index-matched boundaries ignore.
    static void warnRefractiveBoundaries(const ref<Scene>& pScene)
    {
        if (!pScene)
            return;
        for (const auto& pMaterial : pScene->getMaterials())
        {
            if (!isMedium(pMaterial))
                continue;
            auto pBasic = static_ref_cast<BasicMaterial>(pMaterial);
            if (pBasic->getIndexOfRefraction() != 1.f)
                logWarning("Material '{}' holds a medium with index of refraction {}: medium boundaries are "
                           "index-matched (refraction is not implemented), so it is rendered with index 1.",
                           pBasic->getName(), pBasic->getIndexOfRefraction());
        }
    }
};
