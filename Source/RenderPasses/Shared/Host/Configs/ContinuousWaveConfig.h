#pragma once
#include "ConfigUtils.h"
#include "Waveform.h"
#include <cmath>

/// Continuous-wave (amplitude-modulated) time of flight: a path of optical length l is weighted by the waveform w at
/// t = l / modulationWavelength - phase periods, the correlation of the modulated light with the sensor. The weight
/// is w(t) in [-1, 1], or 0.5 w(t) + 0.5 in [0, 1] with unsignedModulation.
struct ContinuousWaveConfig
{
    float modulationWavelength = 1.0f; ///< Path length of one modulation period (scene units).
    float phase = 0.f;                 ///< Sensor phase offset, in periods.
    Waveform waveform = Waveform::Cos;
    bool unsignedModulation = false;   ///< Weight 0.5 w + 0.5 instead of w.

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
        else if (key == "waveform")
            waveform = parseEnumProperty(kWaveforms, value, key);
        else if (key == "unsignedModulation")
            unsignedModulation = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["modulationWavelength"] = modulationWavelength;
        props["phase"] = phase;
        props["waveform"] = enumPropertyName(kWaveforms, waveform);
        props["unsignedModulation"] = unsignedModulation;
    }

    /// Sets the Modulation constants under `modulationVar`.
    void bindShaderData(const ShaderVar& modulationVar) const
    {
        modulationVar["gModulationWavelength"] = modulationWavelength;
        modulationVar["gModulationPhase"] = phase;
        modulationVar["gWaveform"] = uint(waveform);
        modulationVar["gUnsignedModulation"] = uint(unsignedModulation);
    }

    bool renderUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        dirty |= renderWaveformUI(widget, waveform);
        widget.tooltip("Modulation waveform w, zero mean in [-1, 1]. Cos, triangle and box peak at the phase; the "
                       "sawtooth rises from -1 to 1 over each period.", true);

        dirty |= widget.var("Wavelength", modulationWavelength, 0.0001f, 1000.0f);
        widget.tooltip("Path length of one modulation period, in scene units. A path of optical length l is weighted "
                       "by w(l / wavelength - phase).", true);

        dirty |= widget.var("Phase", phase, -1.f, 1.f);
        widget.tooltip("Sensor phase offset, in periods (0.25 = 90 degrees).", true);

        dirty |= widget.checkbox("Unsigned", unsignedModulation);
        widget.tooltip("Weight paths by 0.5 w + 0.5 in [0, 1] instead of w in [-1, 1].", true);
        return dirty;
    }
};
