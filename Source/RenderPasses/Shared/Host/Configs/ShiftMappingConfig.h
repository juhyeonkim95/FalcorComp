#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"

/// Path-length-aware shift mapping: the chart on which the shifted vertex is moved.
enum class ShiftMappingMethod
{
    NO = 0,
    LOCAL_TANGENT_SURFACE = 1,
    BARYCENTRIC = 2,
    RAY_TRACE_HEMISPHERE = 3,
    AREA_ADAPTIVE = 4,
    RAY_TRACE_CHART = 5,
    RADIAL = 6, ///< Along the ray from the path length's minimum on the vertex's plane; ignores the gauge.
};

inline const std::unordered_map<std::string, ShiftMappingMethod> kShiftMappingMethods = {
    {"no", ShiftMappingMethod::NO},
    {"local_tangent", ShiftMappingMethod::LOCAL_TANGENT_SURFACE},
    {"barycentric", ShiftMappingMethod::BARYCENTRIC},
    {"ray_trace", ShiftMappingMethod::RAY_TRACE_HEMISPHERE},
    {"area_adaptive", ShiftMappingMethod::AREA_ADAPTIVE},
    {"ray_trace_chart", ShiftMappingMethod::RAY_TRACE_CHART},
    {"radial", ShiftMappingMethod::RADIAL}
};

enum class GaugeMode
{
    CONSTANT = 0,
    ORTHO_GRAD_START = 1,
    ORTHO_AVG_GRAD = 2,
};

inline const std::unordered_map<std::string, GaugeMode> kGaugeModes = {
    {"constant", GaugeMode::CONSTANT},
    {"grad", GaugeMode::ORTHO_GRAD_START},
    {"avg_grad", GaugeMode::ORTHO_AVG_GRAD}
};

/// Path-length-aware shift mapping (Shared/Shaders/ShiftMapping/ShiftMapping.slang): a vertex is
/// moved on its surface so the path length changes by a given amount, with a Newton solve on the chosen chart.
struct ShiftMappingConfig
{
    ShiftMappingMethod shiftmapMethod = ShiftMappingMethod::NO;
    GaugeMode gaugeMode = GaugeMode::CONSTANT;
    float2 gaugeAxis = float2(1, 0);
    uint newtonMaxIteration = 5;
    float newtonRelativeTolerance = 0.01f;

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "shiftmapMethod")
            shiftmapMethod = parseEnumProperty(kShiftMappingMethods, value, key);
        else if (key == "gaugeMode")
            gaugeMode = parseEnumProperty(kGaugeModes, value, key);
        else if (key == "gaugeAxis")
            gaugeAxis = value;
        else if (key == "NewtonMaxIteration")
            newtonMaxIteration = value;
        else if (key == "NewtonRelativeTolerance")
            newtonRelativeTolerance = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["shiftmapMethod"] = enumPropertyName(kShiftMappingMethods, shiftmapMethod);
        props["gaugeMode"] = enumPropertyName(kGaugeModes, gaugeMode);
        props["gaugeAxis"] = gaugeAxis;
        props["NewtonMaxIteration"] = newtonMaxIteration;
        props["NewtonRelativeTolerance"] = newtonRelativeTolerance;
    }

    /// SHIFT_MAPPING_METHOD and SHIFT_MAPPING_GAUGE_MODE.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)shiftmapMethod));
        defines.add("SHIFT_MAPPING_GAUGE_MODE", std::to_string((uint32_t)gaugeMode));
        return defines;
    }

    /// Sets the shift mapping constants (ShiftMappingCB) under `shiftmapVar`.
    void bindShaderData(const ShaderVar& shiftmapVar) const
    {
        shiftmapVar["gGaugeAxis"] = gaugeAxis;
        shiftmapVar["gNewtonMaxIteration"] = newtonMaxIteration;
        shiftmapVar["gNewtonRelativeTolerance"] = newtonRelativeTolerance;
    }

    /// Shift method (with `methodTooltip`), gauge and Newton solve. `extraUI` is drawn after the method.
    template<typename ExtraUI>
    bool renderUI(Gui::Widgets& widget, const std::string& methodTooltip, ExtraUI&& extraUI)
    {
        bool dirty = false;
        static const Gui::DropdownList kShiftmapMethodList = {
            {(uint32_t)ShiftMappingMethod::NO, "None"},
            {(uint32_t)ShiftMappingMethod::LOCAL_TANGENT_SURFACE, "Local tangent"},
            {(uint32_t)ShiftMappingMethod::BARYCENTRIC, "Barycentric"},
            {(uint32_t)ShiftMappingMethod::RAY_TRACE_HEMISPHERE, "Ray trace"},
            {(uint32_t)ShiftMappingMethod::AREA_ADAPTIVE, "Area adaptive"},
            {(uint32_t)ShiftMappingMethod::RAY_TRACE_CHART, "Ray trace chart"},
            {(uint32_t)ShiftMappingMethod::RADIAL, "Radial"},
        };
        uint32_t method = (uint32_t)shiftmapMethod;
        if (widget.dropdown("Method", kShiftmapMethodList, method))
        {
            shiftmapMethod = (ShiftMappingMethod)method;
            dirty = true;
        }
        widget.tooltip(methodTooltip, true);

        dirty |= extraUI(widget);

        // Radial moves the vertex along the ray from the plane's path-length minimum: no gauge, no 2D Newton solve.
        if (shiftmapMethod != ShiftMappingMethod::NO && shiftmapMethod != ShiftMappingMethod::RADIAL)
        {
            static const Gui::DropdownList kGaugeModeList = {
                {(uint32_t)GaugeMode::CONSTANT, "Constant axis"},
                {(uint32_t)GaugeMode::ORTHO_GRAD_START, "Orthogonal to start gradient"},
                {(uint32_t)GaugeMode::ORTHO_AVG_GRAD, "Orthogonal to average gradient"},
            };
            uint32_t gauge = (uint32_t)gaugeMode;
            if (widget.dropdown("Gauge", kGaugeModeList, gauge))
            {
                gaugeMode = (GaugeMode)gauge;
                dirty = true;
            }
            widget.tooltip("Fixes the direction left free by the one path-length constraint in the 2D Newton solve.", true);

            if (gaugeMode == GaugeMode::CONSTANT)
            {
                dirty |= widget.var("Gauge axis", gaugeAxis, -1.f, 1.f);
                widget.tooltip("Chart-space axis of the constant gauge. (0, 0) picks a random axis per shift.", true);
            }

            dirty |= widget.var("Newton iterations", newtonMaxIteration, 1u, 64u);
            widget.tooltip("Maximum Newton iterations per shift.", true);
        }
        return dirty;
    }

    bool renderUI(Gui::Widgets& widget, const std::string& methodTooltip)
    {
        return renderUI(widget, methodTooltip, [](Gui::Widgets&) { return false; });
    }
};
