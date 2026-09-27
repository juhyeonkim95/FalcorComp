#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"

/// Path-length-aware shift mapping: the chart on which the shifted vertex is moved.
enum class ShiftmapMethod
{
    NO = 0,
    LOCAL_TANGENT_SURFACE = 1,
    BARYCENTRIC = 2,
    RAY_TRACE_HEMISPHERE = 3,
    AREA_ADAPTIVE = 4,
    RAY_TRACE_CHART = 5,
};

static const std::unordered_map<std::string, ShiftmapMethod> ShiftmapMethodTable = {
    {"no", ShiftmapMethod::NO},
    {"local_tangent", ShiftmapMethod::LOCAL_TANGENT_SURFACE},
    {"barycentric", ShiftmapMethod::BARYCENTRIC},
    {"ray_trace", ShiftmapMethod::RAY_TRACE_HEMISPHERE},
    {"area_adaptive", ShiftmapMethod::AREA_ADAPTIVE},
    {"ray_trace_chart", ShiftmapMethod::RAY_TRACE_CHART}
};

enum class GaugeMode
{
    CONSTANT = 0,
    ORTHO_GRAD_START = 1,
    ORTHO_AVG_GRAD = 2,
};

static const std::unordered_map<std::string, GaugeMode> GaugeModeTable = {
    {"constant", GaugeMode::CONSTANT},
    {"grad", GaugeMode::ORTHO_GRAD_START},
    {"avg_grad", GaugeMode::ORTHO_AVG_GRAD}
};

/// Path-length-aware shift mapping (Shared/Shaders/ShiftMapping/PathLengthAwareShiftmapping.slang): a vertex is
/// moved on its surface so the path length changes by a given amount, with a Newton solve on the chosen chart.
struct ShiftMappingConfig
{
    ShiftmapMethod shiftmapMethod = ShiftmapMethod::NO;
    GaugeMode gaugeMode = GaugeMode::CONSTANT;
    float2 gaugeAxis = float2(1, 0);
    uint newtonMaxIteration = 5;
    float newtonRelativeTolerance = 0.01f;

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "shiftmapMethod")
            shiftmapMethod = parseEnumProperty(ShiftmapMethodTable, value, key);
        else if (key == "gaugeMode")
            gaugeMode = parseEnumProperty(GaugeModeTable, value, key);
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
        props["shiftmapMethod"] = enumPropertyName(ShiftmapMethodTable, shiftmapMethod);
        props["gaugeMode"] = enumPropertyName(GaugeModeTable, gaugeMode);
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

    /// Sets the shift mapping constants (Shiftmap_CB) under `shiftmapVar`.
    void bindShaderData(const ShaderVar& shiftmapVar) const
    {
        shiftmapVar["gGaugeAxis"] = gaugeAxis;
        shiftmapVar["gGaugeMode"] = uint(gaugeMode);
        shiftmapVar["gShiftMappingMethod"] = uint(shiftmapMethod);
        shiftmapVar["gNewtonMaxIteration"] = newtonMaxIteration;
        shiftmapVar["gNewtonRelativeTolerance"] = newtonRelativeTolerance;
    }

    /// Shift method (with `methodTooltip`), gauge and Newton solve. `extraUI` is drawn after the method.
    template<typename ExtraUI>
    bool renderUI(Gui::Widgets& widget, const std::string& methodTooltip, ExtraUI&& extraUI)
    {
        bool dirty = false;
        static const Gui::DropdownList kShiftmapMethodList = {
            {(uint32_t)ShiftmapMethod::NO, "None"},
            {(uint32_t)ShiftmapMethod::LOCAL_TANGENT_SURFACE, "Local tangent"},
            {(uint32_t)ShiftmapMethod::BARYCENTRIC, "Barycentric"},
            {(uint32_t)ShiftmapMethod::RAY_TRACE_HEMISPHERE, "Ray trace"},
            {(uint32_t)ShiftmapMethod::AREA_ADAPTIVE, "Area adaptive"},
            {(uint32_t)ShiftmapMethod::RAY_TRACE_CHART, "Ray trace chart"},
        };
        uint32_t method = (uint32_t)shiftmapMethod;
        if (widget.dropdown("Method", kShiftmapMethodList, method))
        {
            shiftmapMethod = (ShiftmapMethod)method;
            dirty = true;
        }
        widget.tooltip(methodTooltip, true);

        dirty |= extraUI(widget);

        if (shiftmapMethod != ShiftmapMethod::NO)
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
