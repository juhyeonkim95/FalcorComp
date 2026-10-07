#pragma once
#include "ConfigUtils.h"

/// Time-gate kernel over the path length (TIME_GATE_* in Shared/Shaders/Utils/TimeGate.slang).
enum class TimeGateMode : uint32_t
{
    All = 0,
    Box = 1,
    Tent = 2,
    Cos = 3,
    Exp = 4,
    Gaussian = 5,
    Epanechnikov = 6,
    Perlin = 8,
    ExpTwoSide = 9,
};

inline const std::unordered_map<std::string, TimeGateMode> kTimeGateModes = {
    {"all", TimeGateMode::All},
    {"box", TimeGateMode::Box},
    {"tent", TimeGateMode::Tent},
    {"cos", TimeGateMode::Cos},
    {"exp", TimeGateMode::Exp},
    {"gaussian", TimeGateMode::Gaussian},
    {"epanechnikov", TimeGateMode::Epanechnikov},
    {"perlin", TimeGateMode::Perlin},
    {"exp_two_side", TimeGateMode::ExpTwoSide},
};

/// Gate kernel dropdown, with the kernels implemented by pathLengthImportance(). Returns true when the kernel changed.
inline bool renderTimeGateModeUI(Gui::Widgets& widget, TimeGateMode& mode)
{
    static const Gui::DropdownList kTimeGateModeList = {
        {(uint32_t)TimeGateMode::Box, "Box"},
        {(uint32_t)TimeGateMode::Tent, "Tent"},
        {(uint32_t)TimeGateMode::Gaussian, "Gaussian"},
        {(uint32_t)TimeGateMode::Exp, "Exponential (one-sided)"},
        {(uint32_t)TimeGateMode::ExpTwoSide, "Exponential (two-sided)"},
        {(uint32_t)TimeGateMode::Epanechnikov, "Epanechnikov"},
        {(uint32_t)TimeGateMode::Perlin, "Perlin"},
        {(uint32_t)TimeGateMode::Cos, "Cos"},
        {(uint32_t)TimeGateMode::All, "All (no gating)"},
    };
    uint32_t value = (uint32_t)mode;
    if (!widget.dropdown("Gate kernel", kTimeGateModeList, value))
        return false;
    mode = (TimeGateMode)value;
    return true;
}
