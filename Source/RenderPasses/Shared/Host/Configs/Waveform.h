#pragma once
#include "ConfigUtils.h"

/// Periodic waveform (WAVEFORM_* in Shared/Shaders/Utils/Waveform.slang): zero mean, in [-1, 1].
enum class Waveform : uint32_t
{
    Cos = 0,
    Triangle = 1,
    Box = 2,
    Sawtooth = 3,
};

inline const std::unordered_map<std::string, Waveform> kWaveforms = {
    {"cos", Waveform::Cos},
    {"triangle", Waveform::Triangle},
    {"box", Waveform::Box},
    {"sawtooth", Waveform::Sawtooth},
};

/// Waveform dropdown. Returns true when the waveform changed.
inline bool renderWaveformUI(Gui::Widgets& widget, Waveform& waveform)
{
    static const Gui::DropdownList kWaveformList = {
        {(uint32_t)Waveform::Cos, "Cos"},
        {(uint32_t)Waveform::Triangle, "Triangle"},
        {(uint32_t)Waveform::Box, "Box"},
        {(uint32_t)Waveform::Sawtooth, "Sawtooth"},
    };
    uint32_t value = (uint32_t)waveform;
    if (!widget.dropdown("Waveform", kWaveformList, value))
        return false;
    waveform = (Waveform)value;
    return true;
}
