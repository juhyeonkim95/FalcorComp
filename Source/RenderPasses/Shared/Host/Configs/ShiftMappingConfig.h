#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"
#include <cmath>

/// Path-length-aware shift mapping: the chart on which the shifted vertex is moved.
enum class ShiftMappingMethod
{
    Identity = 0, ///< The vertex stays fixed (naive reuse).
    LocalTangent = 1,
    Barycentric = 2,
    RayTrace = 3,
    AreaAdaptive = 4,
    RayTraceChart = 5,
    Radial = 6, ///< Along the ray from the path length's minimum on the vertex's plane; ignores the gauge.
};

inline const std::unordered_map<std::string, ShiftMappingMethod> kShiftMappingMethods = {
    {"no", ShiftMappingMethod::Identity},
    {"local_tangent", ShiftMappingMethod::LocalTangent},
    {"barycentric", ShiftMappingMethod::Barycentric},
    {"ray_trace", ShiftMappingMethod::RayTrace},
    {"area_adaptive", ShiftMappingMethod::AreaAdaptive},
    {"ray_trace_chart", ShiftMappingMethod::RayTraceChart},
    {"radial", ShiftMappingMethod::Radial}
};

enum class GaugeMode
{
    Constant = 0,
    OrthoGradStart = 1,
    OrthoAvgGrad = 2,
};

inline const std::unordered_map<std::string, GaugeMode> kGaugeModes = {
    {"constant", GaugeMode::Constant},
    {"grad", GaugeMode::OrthoGradStart},
    {"avg_grad", GaugeMode::OrthoAvgGrad}
};

/// Path-length-aware shift mapping (Shared/Shaders/ShiftMapping/ShiftMapping.slang): a vertex is
/// moved on its surface so the path length changes by a given amount, with a Newton solve on the chosen chart.
struct ShiftMappingConfig
{
    ShiftMappingMethod shiftMappingMethod = ShiftMappingMethod::Identity;
    GaugeMode gaugeMode = GaugeMode::Constant;
    float2 gaugeAxis = float2(1, 0);
    uint newtonMaxIteration = 10;
    /// Relative to the path length change; looser solves bias reuse. The solve never resolves lengths below the float32
    /// spacing of the path lengths and coordinates involved (ShiftMapping.slang).
    float newtonRelativeTolerance = 1e-6f;
    /// Ray charts only: rejects shifts that move the vertex farther than this in chart coordinates (0 disables).
    /// The gauge system can have several roots for large moves, so the reverse solve may not return; see ShiftMapping.slang.
    float rayChartMaxDisplacement = 0.f;
    /// Keep a shift only if the reverse shift maps it back to its start (a second shift each): the accepted shifts are
    /// then one-to-one wherever the solver could reach another root.
    bool roundTripCheck = false;

    void validate() const
    {
        if (newtonMaxIteration < 1 || newtonMaxIteration > 64)
            FALCOR_THROW("NewtonMaxIteration must be in [1, 64].");
        if (!std::isfinite(newtonRelativeTolerance) || newtonRelativeTolerance <= 0.f)
            FALCOR_THROW("NewtonRelativeTolerance must be finite and greater than zero.");
        if (!std::isfinite(gaugeAxis.x) || !std::isfinite(gaugeAxis.y))
            FALCOR_THROW("gaugeAxis must be finite.");
        if (!std::isfinite(rayChartMaxDisplacement) || rayChartMaxDisplacement < 0.f)
            FALCOR_THROW("rayChartMaxDisplacement must be finite and non-negative (0 disables it).");
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "shiftMappingMethod")
            shiftMappingMethod = parseEnumProperty(kShiftMappingMethods, value, key);
        else if (key == "gaugeMode")
            gaugeMode = parseEnumProperty(kGaugeModes, value, key);
        else if (key == "gaugeAxis")
            gaugeAxis = value;
        else if (key == "NewtonMaxIteration")
            newtonMaxIteration = value;
        else if (key == "NewtonRelativeTolerance")
            newtonRelativeTolerance = value;
        else if (key == "rayChartMaxDisplacement")
            rayChartMaxDisplacement = value;
        else if (key == "shiftRoundTripCheck")
            roundTripCheck = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["shiftMappingMethod"] = enumPropertyName(kShiftMappingMethods, shiftMappingMethod);
        props["gaugeMode"] = enumPropertyName(kGaugeModes, gaugeMode);
        props["gaugeAxis"] = gaugeAxis;
        props["NewtonMaxIteration"] = newtonMaxIteration;
        props["NewtonRelativeTolerance"] = newtonRelativeTolerance;
        props["rayChartMaxDisplacement"] = rayChartMaxDisplacement;
        props["shiftRoundTripCheck"] = roundTripCheck;
    }

    /// SHIFT_MAPPING_METHOD, SHIFT_MAPPING_GAUGE_MODE and SHIFT_ROUND_TRIP_CHECK.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)shiftMappingMethod));
        defines.add("SHIFT_MAPPING_GAUGE_MODE", std::to_string((uint32_t)gaugeMode));
        defines.add("SHIFT_ROUND_TRIP_CHECK", roundTripCheck ? "1" : "0");
        return defines;
    }

    /// Sets the shift mapping constants (ShiftMappingCB) under `var`.
    void bindShaderData(const ShaderVar& var) const
    {
        var["gGaugeAxis"] = gaugeAxis;
        var["gNewtonMaxIteration"] = newtonMaxIteration;
        var["gNewtonRelativeTolerance"] = newtonRelativeTolerance;
        var["gRayChartMaxDisplacement"] = rayChartMaxDisplacement;
    }

    /// Shift method (with `methodTooltip`), gauge and Newton solve. `extraUI` is drawn after the method.
    template<typename ExtraUI>
    bool renderUI(Gui::Widgets& widget, const std::string& methodTooltip, ExtraUI&& extraUI)
    {
        bool dirty = false;
        static const Gui::DropdownList kShiftMappingMethodList = {
            {(uint32_t)ShiftMappingMethod::Identity, "None"},
            {(uint32_t)ShiftMappingMethod::LocalTangent, "Local tangent"},
            {(uint32_t)ShiftMappingMethod::Barycentric, "Barycentric"},
            {(uint32_t)ShiftMappingMethod::RayTrace, "Ray trace"},
            {(uint32_t)ShiftMappingMethod::AreaAdaptive, "Area adaptive"},
            {(uint32_t)ShiftMappingMethod::RayTraceChart, "Ray trace chart"},
            {(uint32_t)ShiftMappingMethod::Radial, "Radial"},
        };
        uint32_t method = (uint32_t)shiftMappingMethod;
        if (widget.dropdown("Method", kShiftMappingMethodList, method))
        {
            shiftMappingMethod = (ShiftMappingMethod)method;
            dirty = true;
        }
        widget.tooltip(methodTooltip, true);

        if (shiftMappingMethod != ShiftMappingMethod::Identity)
        {
            dirty |= widget.checkbox("Round-trip check", roundTripCheck);
            widget.tooltip("Keep a shift only if shifting back returns to its start, so that the shifts used are "
                           "one-to-one even where the solve could reach another solution. Costs a second shift.", true);
        }

        dirty |= extraUI(widget);

        // Radial moves the vertex along the ray from the plane's path-length minimum: no gauge, no 2D Newton solve.
        if (shiftMappingMethod != ShiftMappingMethod::Identity && shiftMappingMethod != ShiftMappingMethod::Radial)
        {
            static const Gui::DropdownList kGaugeModeList = {
                {(uint32_t)GaugeMode::Constant, "Constant axis"},
                {(uint32_t)GaugeMode::OrthoGradStart, "Orthogonal to start gradient"},
                {(uint32_t)GaugeMode::OrthoAvgGrad, "Orthogonal to average gradient"},
            };
            uint32_t gauge = (uint32_t)gaugeMode;
            if (widget.dropdown("Gauge", kGaugeModeList, gauge))
            {
                gaugeMode = (GaugeMode)gauge;
                dirty = true;
            }
            widget.tooltip("Fixes the direction left free by the one path-length constraint in the 2D Newton solve.", true);

            if (gaugeMode == GaugeMode::Constant)
            {
                dirty |= widget.var("Gauge axis", gaugeAxis, -1.f, 1.f);
                widget.tooltip("Chart-space axis of the constant gauge. (0, 0) picks a random axis per shift.", true);
            }

            dirty |= widget.var("Newton iterations", newtonMaxIteration, 1u, 64u);
            widget.tooltip("Maximum Newton iterations per shift.", true);

            if (shiftMappingMethod == ShiftMappingMethod::RayTrace || shiftMappingMethod == ShiftMappingMethod::RayTraceChart ||
                shiftMappingMethod == ShiftMappingMethod::AreaAdaptive)
            {
                dirty |= widget.var("Ray chart max displacement", rayChartMaxDisplacement, 0.f, 1.f);
                widget.tooltip("Rejects ray-chart shifts that move farther than this in chart coordinates; 0 disables.", true);
            }
        }
        return dirty;
    }

    bool renderUI(Gui::Widgets& widget, const std::string& methodTooltip)
    {
        return renderUI(widget, methodTooltip, [](Gui::Widgets&) { return false; });
    }
};
