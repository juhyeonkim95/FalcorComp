#pragma once
#include "ConfigUtils.h"
#include "Utils/Transient/Transient.h"
#include <algorithm>
#include <cmath>

/// The gate center of the current and previous frame, and the position in the scan.
struct TimeGateState
{
    uint index = 0;       ///< Scan position; advanced by shiftGate or scripts.
    float current = 0.f;  ///< This frame's gate center (tcurr).
    float previous = 0.f; ///< Last frame's gate center (tprev).

    void advance() { ++index; }
    void endFrame() { previous = current; }
};

/// Time gate: a kernel of width timeGateWindow whose center scans timeBin positions in [timeMin, timeMax).
struct TimeGateConfig
{
    float timeMin = 9.0f;
    float timeMax = 12.0f;
    uint timeBin = 512;
    float timeGateWindow = 0.05f;
    TimeGateMode timeGateMode = TimeGateMode::BOX;
    bool shiftGate = false; ///< Advance the gate one bin per frame, wrapping from timeMax to timeMin.

    /// Center of gate `index`. Equal endpoints give a fixed gate.
    float gateCenter(uint index) const { return float(index % timeBin) / timeBin * (timeMax - timeMin) + timeMin; }

    /// Sets this frame's gate center from the scan position.
    void beginFrame(TimeGateState& state) const { state.current = gateCenter(state.index); }

    /// Sets the TimeGate constants (window, kernel, tcurr, tprev) under `timeGateVar`.
    void bindShaderData(const ShaderVar& timeGateVar, const TimeGateState& state) const
    {
        timeGateVar["time_gate_window"] = timeGateWindow;
        timeGateVar["time_gate_mode"] = uint(timeGateMode);
        timeGateVar["tcurr"] = state.current;
        timeGateVar["tprev"] = state.previous;
    }

    void validate() const
    {
        if (timeBin == 0)
            FALCOR_THROW("timeBin must be greater than zero.");
        if (!std::isfinite(timeGateWindow) || timeGateWindow <= 0.f)
            FALCOR_THROW("timeGateWindow must be finite and greater than zero.");
        if (!std::isfinite(timeMin) || !std::isfinite(timeMax) || timeMin > timeMax)
            FALCOR_THROW("The gate range must be finite with timeMin <= timeMax.");
    }

    /// Returns false if `key` is not a time gate property. "timeCenter" is applied by applyTimeCenter().
    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "timeMin")
            timeMin = value;
        else if (key == "timeMax")
            timeMax = value;
        else if (key == "timeCenter")
            ; // Applied after all properties, so it overrides timeMin and timeMax in any order.
        else if (key == "timeBin")
            timeBin = value;
        else if (key == "timeGateWindow")
            timeGateWindow = value;
        else if (key == "timeGateMode")
            timeGateMode = parseEnumProperty(TimeGateModeTable, value, key);
        else if (key == "shiftGate")
            shiftGate = value;
        else
            return false;
        return true;
    }

    /// Optional "timeCenter": a fixed gate, timeMin = timeMax = timeCenter. Call after parsing.
    void applyTimeCenter(const Properties& props)
    {
        if (props.has("timeCenter"))
            timeMin = timeMax = props.get<float>("timeCenter");
    }

    void serialize(Properties& props) const
    {
        props["timeMin"] = timeMin;
        props["timeMax"] = timeMax;
        props["timeBin"] = timeBin;
        props["timeGateWindow"] = timeGateWindow;
        props["timeGateMode"] = enumPropertyName(TimeGateModeTable, timeGateMode);
        props["shiftGate"] = shiftGate;
    }

    /// Gate kernel, window and center (fixed or shifting). `shiftGateNote` is appended to the Shift gate tooltip.
    bool renderUI(Gui::Widgets& widget, float currentCenter, const std::string& shiftGateNote = "")
    {
        bool dirty = false;
        // Only the kernels implemented by pathLengthImportance() are offered.
        static const Gui::DropdownList kTimeGateModeList = {
            {(uint32_t)TimeGateMode::BOX, "Box"},
            {(uint32_t)TimeGateMode::TENT, "Tent"},
            {(uint32_t)TimeGateMode::COS, "Cos"},
            {(uint32_t)TimeGateMode::ALL, "All (no gating)"},
        };
        uint32_t mode = (uint32_t)timeGateMode;
        if (widget.dropdown("Gate kernel", kTimeGateModeList, mode))
        {
            timeGateMode = (TimeGateMode)mode;
            dirty = true;
        }
        widget.tooltip("Weight of a path as a function of its total optical length (laser -> scene -> camera) "
                       "relative to the gate center.", true);

        dirty |= widget.var("Gate window", timeGateWindow, 0.001f, 1000.0f);
        widget.tooltip("Gate width in path-length units (scene units). The output is divided by it.", true);

        if (widget.checkbox("Shift gate", shiftGate))
        {
            // Start a shifting scan from a fixed gate with a default range and resolution.
            if (shiftGate && timeMax <= timeMin)
            {
                timeMax = 1.2f * timeMin;
                timeBin = 100;
            }
            dirty = true;
        }
        widget.tooltip("Off: a fixed gate at Gate center.\nOn: the gate moves one step per frame from Gate min "
                       "toward Gate max, then starts again at Gate min." + shiftGateNote +
                       " Turning it on from a fixed gate sets Gate max = 1.2 x Gate min and 100 bins.", true);

        if (!shiftGate)
        {
            float center = timeMin;
            if (widget.var("Gate center", center, 0.0f, 1000.0f))
            {
                timeMin = timeMax = center;
                dirty = true;
            }
            widget.tooltip("Gate center in path-length units.", true);
        }
        else
        {
            dirty |= widget.var("Gate min", timeMin, 0.0f, timeMax);
            widget.tooltip("First gate center, in path-length units.", true);

            dirty |= widget.var("Gate max", timeMax, timeMin, 1000.0f);
            widget.tooltip("End of the scan, in path-length units. The last gate center is Gate max - Gate step.", true);

            dirty |= widget.var("Gate bins", timeBin, 1u, 1u << 16);
            widget.tooltip("Number of gate centers from Gate min to Gate max.", true);

            // The step is derived from the bins; editing it picks the nearest bin count.
            const float range = timeMax - timeMin;
            float gateStep = range / timeBin;
            if (range > 0.f && widget.var("Gate step", gateStep, 1e-4f, range))
            {
                timeBin = std::max(1u, (uint)std::lround(range / gateStep));
                dirty = true;
            }
            widget.tooltip("Gate center shift per frame, in path-length units. Sets Gate bins to the nearest count.", true);
            if (range <= 0.f)
                widget.text("Set Gate max above Gate min to shift the gate.");
        }

        widget.text(fmt::format("Current gate center: {:.4f}", currentCenter));
        return dirty;
    }
};
