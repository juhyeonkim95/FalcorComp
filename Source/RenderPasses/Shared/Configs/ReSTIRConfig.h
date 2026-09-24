#pragma once
#include "ConfigUtils.h"

/// Path-length-aware shift mapping: the chart on which the reconnection vertex is moved.
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

/// Spatial and temporal reuse with path-length-aware shift mapping.
struct ReSTIRConfig
{
    uint spatialReuseIteration = 1;
    uint spatialReuseNeighborCount = 5;
    float spatialReuseGatherRadius = 10.0f; ///< Pixels.
    bool useTemporalReuse = false;
    float temporalHistoryLength = 20.0f;    ///< History cap in frames of samples; 0 ignores it, negative is uncapped.

    ShiftmapMethod shiftmapMethod = ShiftmapMethod::NO;
    GaugeMode gaugeMode = GaugeMode::CONSTANT;
    float2 gaugeAxis = float2(1, 0);
    uint newtonMaxIteration = 5;
    float newtonRelativeTolerance = 0.01f;
    float reconnectionRoughnessThreshold = 0.25f; ///< Both vertices of a reconnection segment must be rougher.

    uint2 laserHitVBufferRes = uint2(256, 256);

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "spatialReuseIteration")
            spatialReuseIteration = value;
        else if (key == "spatialReuseNeighborCount")
            spatialReuseNeighborCount = value;
        else if (key == "spatialReuseGatherRadius")
            spatialReuseGatherRadius = value;
        else if (key == "useTemporalReuse")
            useTemporalReuse = value;
        else if (key == "temporalHistoryLength")
            temporalHistoryLength = value;
        else if (key == "shiftmapMethod")
            shiftmapMethod = parseEnumProperty(ShiftmapMethodTable, std::string(value), key);
        else if (key == "gaugeMode")
            gaugeMode = parseEnumProperty(GaugeModeTable, std::string(value), key);
        else if (key == "gaugeAxis")
            gaugeAxis = value;
        else if (key == "NewtonMaxIteration")
            newtonMaxIteration = value;
        else if (key == "NewtonRelativeTolerance")
            newtonRelativeTolerance = value;
        else if (key == "specularRoughnessThreshold")
            reconnectionRoughnessThreshold = value;
        else if (key == "laserHitVBufferRes")
            laserHitVBufferRes = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["spatialReuseIteration"] = spatialReuseIteration;
        props["spatialReuseNeighborCount"] = spatialReuseNeighborCount;
        props["spatialReuseGatherRadius"] = spatialReuseGatherRadius;
        props["useTemporalReuse"] = useTemporalReuse;
        props["temporalHistoryLength"] = temporalHistoryLength;
        props["shiftmapMethod"] = enumPropertyName(ShiftmapMethodTable, shiftmapMethod);
        props["gaugeMode"] = enumPropertyName(GaugeModeTable, gaugeMode);
        props["gaugeAxis"] = gaugeAxis;
        props["NewtonMaxIteration"] = newtonMaxIteration;
        props["NewtonRelativeTolerance"] = newtonRelativeTolerance;
        props["specularRoughnessThreshold"] = reconnectionRoughnessThreshold;
        props["laserHitVBufferRes"] = laserHitVBufferRes;
    }

    /// Spatial and temporal reuse. `temporalNote` is appended to the Temporal reuse tooltip.
    bool renderReuseUI(Gui::Widgets& widget, const std::string& temporalNote = "")
    {
        bool dirty = false;
        dirty |= widget.var("Spatial iterations", spatialReuseIteration, 0u, 16u);
        widget.tooltip("Spatial reuse passes per frame. 0 disables spatial reuse.", true);

        dirty |= widget.var("Spatial neighbors", spatialReuseNeighborCount, 1u, 64u);
        widget.tooltip("Neighbor pixels resampled in each spatial pass.", true);

        dirty |= widget.var("Spatial radius (px)", spatialReuseGatherRadius, 1.f, 128.f);
        widget.tooltip("Radius, in pixels, within which spatial neighbors are chosen.", true);

        dirty |= widget.checkbox("Temporal reuse", useTemporalReuse);
        widget.tooltip("Resample the previous frame's reservoir (reprojected with motion vectors when the mvec input "
                       "is connected)." + temporalNote, true);

        if (useTemporalReuse)
        {
            dirty |= widget.var("History length (frames)", temporalHistoryLength, -1.f, 100000.f);
            widget.tooltip("Cap on the history's sample count, in frames of samples per pixel. 0 ignores the "
                           "history; a negative value leaves it uncapped.", true);
        }
        return dirty;
    }

    /// Shift method, reconnection threshold, gauge and Newton solve.
    bool renderShiftMappingUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        static const Gui::DropdownList kShiftmapMethodList = {
            {(uint32_t)ShiftmapMethod::NO, "None (naive reuse)"},
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
        widget.tooltip("How a reused path is fitted to the target pixel's gate. The reconnection vertex is moved so "
                       "the path length changes by the gate difference, using a Newton solve on the chosen chart.\n"
                       "None keeps the vertex fixed (naive reuse).", true);

        dirty |= widget.var("Reconnection roughness threshold", reconnectionRoughnessThreshold, 0.f, 1.f);
        widget.tooltip("A path can reconnect at a segment only if both of its vertices are rougher than this.", true);

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
};
