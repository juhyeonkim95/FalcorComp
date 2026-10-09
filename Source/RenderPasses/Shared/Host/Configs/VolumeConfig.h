#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/Scene.h"
#include "Scene/Material/BasicMaterial.h"
#include <map>
#include <set>
#include <string>

/// Participating media (Shared/Shaders/Volumes/Media.slang): homogeneous media inside closed meshes whose material has
/// volume absorption or scattering, with the material's index of refraction. Their surfaces are smooth interfaces.
struct VolumeConfig
{
    /// Full-precision properties of the medium of a material, replacing the material's own: BasicMaterial stores them
    /// as 16-bit floats (at most 65504 per scene unit, about 3 significant digits).
    struct MediumProperties
    {
        float3 scattering = float3(0.f); ///< Per scene unit.
        float3 absorption = float3(0.f); ///< Per scene unit.
        float anisotropy = 0.f;          ///< Henyey-Greenstein g.

        bool isMedium() const { return any(scattering > 0.f) || any(absorption > 0.f); }
    };

    bool useVolumes = false;
    uint maxScatterEvents = 1024; ///< Maximum scattering events in media on a camera path.
    std::map<std::string, MediumProperties> media; ///< Material name -> medium properties.

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

    /// media: {"name": {"scattering": [..], "absorption": [..], "anisotropy": ..}}, missing entries zero.
    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "useVolumes")
            useVolumes = value;
        else if (key == "maxScatterEvents")
            maxScatterEvents = value;
        else if (key == "media")
        {
            media.clear();
            const Properties objects = value;
            for (const auto& [name, object] : objects)
            {
                const Properties props = object;
                MediumProperties& medium = media[name];
                medium.scattering = props.get<float3>("scattering", float3(0.f));
                medium.absorption = props.get<float3>("absorption", float3(0.f));
                medium.anisotropy = props.get<float>("anisotropy", 0.f);
            }
        }
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["useVolumes"] = useVolumes;
        props["maxScatterEvents"] = maxScatterEvents;
        if (!media.empty())
        {
            Properties objects;
            for (const auto& [name, medium] : media)
            {
                Properties object;
                object["scattering"] = medium.scattering;
                object["absorption"] = medium.absorption;
                object["anisotropy"] = medium.anisotropy;
                objects[name] = object;
            }
            props["media"] = objects;
        }
    }

    bool renderUI(Gui::Widgets& widget)
    {
        bool dirty = widget.checkbox("Participating media", useVolumes);
        widget.tooltip("Render the homogeneous media inside closed meshes whose material has volume absorption or "
                       "scattering. Their surfaces are smooth interfaces with the material's index of refraction.", true);
        if (useVolumes)
        {
            dirty |= widget.var("Max scatter events", maxScatterEvents, 1u, 1u << 20);
            widget.tooltip("Maximum number of scattering events in media on a camera path.", true);
            for (const auto& [name, medium] : media)
                widget.text(fmt::format("{}: scattering {}, absorption {}, g {}", name, medium.scattering.x,
                    medium.absorption.x, medium.anisotropy));
        }
        return dirty;
    }

    /// Whether a material holds a medium (as isMediumMaterial in Media.slang): its properties in `media`, or its own.
    bool isMedium(const ref<Material>& pMaterial) const
    {
        if (auto it = media.find(pMaterial->getName()); it != media.end())
            return it->second.isMedium();
        auto pBasic = dynamic_ref_cast<BasicMaterial>(pMaterial);
        return pBasic && (any(pBasic->getVolumeAbsorption() > 0.f) || any(pBasic->getVolumeScattering() > 0.f));
    }

    bool hasMedia(const ref<Scene>& pScene) const
    {
        if (pScene)
            for (const auto& pMaterial : pScene->getMaterials())
                if (isMedium(pMaterial))
                    return true;
        return false;
    }

    /// Per material, StructuredBuffer<MediumOverride> in Media.slang: (scattering, anisotropy) and (absorption, 1) for
    /// the materials in `media`, zero for the others. Logs the names that match no material.
    ref<Buffer> createMediumBuffer(ref<Device> pDevice, const Scene& scene, const char* pass) const
    {
        const uint32_t count = std::max<uint32_t>(scene.getMaterialCount(), 1);
        std::vector<float4> data(2 * count, float4(0.f));
        std::set<std::string> found;
        for (uint32_t i = 0; i < scene.getMaterialCount(); ++i)
        {
            const std::string& name = scene.getMaterial(MaterialID(i))->getName();
            if (auto it = media.find(name); it != media.end())
            {
                data[2 * i + 0] = float4(it->second.scattering, it->second.anisotropy);
                data[2 * i + 1] = float4(it->second.absorption, 1.f);
                found.insert(name);
            }
        }
        for (const auto& [name, medium] : media)
            if (!found.count(name))
                logWarning("{}: no material is named '{}' (media).", pass, name);
        return pDevice->createStructuredBuffer(2 * sizeof(float4), count, ResourceBindFlags::ShaderResource,
            MemoryType::DeviceLocal, data.data(), false);
    }
};
