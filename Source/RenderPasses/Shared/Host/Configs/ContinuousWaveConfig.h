#pragma once
#include "ConfigUtils.h"
#include "Utils/Transient/Transient.h"
#include <cmath>

/// Continuous-wave (amplitude-modulated) time of flight: a path of optical length l is weighted by
/// cos(2 pi (l / modulationWavelength - phase)), the correlation of the modulated light with the sensor.
/// Uses the cos kernel of Utils/Transient/TransientUtils.slang (pathLengthImportance).
struct ContinuousWaveConfig
{
    float modulationWavelength = 1.0f; ///< Path length of one modulation period (scene units).
    float phase = 0.f;                 ///< Sensor phase offset, in periods.

    void validate() const
    {
        if (!std::isfinite(modulationWavelength) || modulationWavelength <= 0.f)
            FALCOR_THROW("modulationWavelength must be finite and greater than zero.");
        if (!std::isfinite(phase))
            FALCOR_THROW("phase must be finite.");
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "modulationWavelength")
            modulationWavelength = value;
        else if (key == "phase")
            phase = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["modulationWavelength"] = modulationWavelength;
        props["phase"] = phase;
    }

    /// Sets the TimeGate constants for the cos kernel: window = wavelength, center = phase * wavelength.
    void bindShaderData(const ShaderVar& timeGateVar) const
    {
        timeGateVar["time_gate_window"] = modulationWavelength;
        timeGateVar["time_gate_mode"] = uint(TimeGateMode::COS);
        timeGateVar["tcurr"] = phase * modulationWavelength;
        timeGateVar["tprev"] = phase * modulationWavelength;
    }

    bool renderUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        dirty |= widget.var("Wavelength", modulationWavelength, 0.001f, 1000.0f);
        widget.tooltip("Path length of one modulation period, in scene units. A path of optical length l is weighted "
                       "by cos(2 pi (l / wavelength - phase)).", true);

        dirty |= widget.var("Phase", phase, -1.f, 1.f);
        widget.tooltip("Sensor phase offset, in periods (0.25 = 90 degrees).", true);
        return dirty;
    }
};
