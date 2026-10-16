#pragma once
#include "ConfigUtils.h"
#include "Scene/Camera/Camera.h"
#include <cmath>

/// Transport probing mode (PROBING_MODE in Shared/Shaders/Probing/Probing.slang).
enum class ProbingMode : uint32_t
{
    None = 0,
    Epipolar = 1,
    NonEpipolar = 2,
    Masks = 3,
};

inline const std::unordered_map<std::string, ProbingMode> kProbingModes = {
    {"none", ProbingMode::None},
    {"epipolar", ProbingMode::Epipolar},
    {"non_epipolar", ProbingMode::NonEpipolar},
    {"masks", ProbingMode::Masks},
};

/// Transport probing (O'Toole et al. 2012, 2014; Shared/Shaders/Probing/Probing.slang): each path is weighted by
/// whether its projector ray, from the light (a projector or point light) to the path's last vertex, lies on the
/// epipolar line of its camera ray. Epipolar keeps the direct and retro-reflective light, non_epipolar the rest, and
/// masks simulates the K random mask/pattern pairs that approximate non_epipolar in hardware.
struct ProbingConfig
{
    ProbingMode mode = ProbingMode::None;
    float lineWidth = 1.f; ///< Width of an epipolar line, in camera pixels (the vertical angle of a pixel at the center).
    uint maskCount = 128;  ///< Masks: K mask/pattern pairs, 1 to 128.
    uint seed = 0;         ///< Masks: seed of the random masks.

    void validate() const
    {
        if (!std::isfinite(lineWidth) || lineWidth <= 0.f)
            FALCOR_THROW("probingLineWidth must be finite and greater than zero.");
        if (maskCount == 0 || maskCount > 128)
            FALCOR_THROW("probingMaskCount must be in [1, 128].");
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "probing")
            mode = parseEnumProperty(kProbingModes, value, key);
        else if (key == "probingLineWidth")
            lineWidth = value;
        else if (key == "probingMaskCount")
            maskCount = value;
        else if (key == "probingSeed")
            seed = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["probing"] = enumPropertyName(kProbingModes, mode);
        props["probingLineWidth"] = lineWidth;
        props["probingMaskCount"] = maskCount;
        props["probingSeed"] = seed;
    }

    /// PROBING_MODE.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("PROBING_MODE", std::to_string((uint32_t)mode));
        return defines;
    }

    /// Sets the Probing constants under `probingVar`, for `camera` rendering `frameDim` pixels.
    void bindShaderData(const ShaderVar& probingVar, const Camera& camera, uint2 frameDim) const
    {
        const float tanHalfFovY = 0.5f * camera.getFrameHeight() / camera.getFocalLength();
        const float pixelAngle = 2.f * std::atan(tanHalfFovY) / float(frameDim.y);
        const float3 forward = normalize(camera.getTarget() - camera.getPosition());
        const float3 right = normalize(cross(forward, camera.getUpVector()));
        probingVar["gProbingLineAngle"] = lineWidth * pixelAngle;
        probingVar["gProbingLineWidth"] = lineWidth;
        probingVar["gProbingMaskCount"] = maskCount;
        probingVar["gProbingSeed"] = seed;
        probingVar["gProbingCameraForward"] = forward;
        probingVar["gProbingCameraUp"] = cross(right, forward);
        probingVar["gProbingTanHalfFovY"] = tanHalfFovY;
        probingVar["gProbingFrameHeight"] = float(frameDim.y);
    }

    bool renderUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        static const Gui::DropdownList kModeList = {
            {(uint32_t)ProbingMode::None, "None"},
            {(uint32_t)ProbingMode::Epipolar, "Epipolar (direct + retro-reflective)"},
            {(uint32_t)ProbingMode::NonEpipolar, "Non-epipolar (indirect)"},
            {(uint32_t)ProbingMode::Masks, "Random masks (K pairs)"},
        };
        uint32_t probing = (uint32_t)mode;
        if (widget.dropdown("Probing", kModeList, probing))
        {
            mode = (ProbingMode)probing;
            dirty = true;
        }
        widget.tooltip("Weight each path by whether its projector ray lies on the epipolar line of its camera ray "
                       "(the planes through the camera and the light; the image rows when the light is at the camera). "
                       "Epipolar keeps the direct and retro-reflective light, non-epipolar the rest; random masks "
                       "approximate non-epipolar with K camera masks and their complements as patterns.", true);
        if (mode != ProbingMode::None)
        {
            dirty |= widget.var("Line width (pixels)", lineWidth, 0.01f, 100.f);
            widget.tooltip("Width of an epipolar line, in camera pixels.", true);
        }
        if (mode == ProbingMode::Masks)
        {
            dirty |= widget.var("Masks (K)", maskCount, 1u, 128u);
            widget.tooltip("Number of mask/pattern pairs.", true);
            dirty |= widget.var("Seed", seed);
            widget.tooltip("Seed of the random masks.", true);
        }
        return dirty;
    }
};
