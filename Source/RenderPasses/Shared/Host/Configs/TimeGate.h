#pragma once
#include "ConfigUtils.h"

/// Time-gate kernel over the path length (TIME_GATE_* in Shared/Shaders/Utils/TimeGate.slang).
enum class TimeGateMode : uint32_t
{
    ALL = 0,
    BOX = 1,
    TENT = 2,
    COS = 3,
    EXP = 4,
    GAUSSIAN = 5,
    EPANECHNIKOV = 6,
    PERLIN = 8,
    EXP_TWO_SIDE = 9,
};

inline const std::unordered_map<std::string, TimeGateMode> kTimeGateModes = {
    {"all", TimeGateMode::ALL},
    {"box", TimeGateMode::BOX},
    {"tent", TimeGateMode::TENT},
    {"cos", TimeGateMode::COS},
    {"exp", TimeGateMode::EXP},
    {"gaussian", TimeGateMode::GAUSSIAN},
    {"epanechnikov", TimeGateMode::EPANECHNIKOV},
    {"perlin", TimeGateMode::PERLIN},
    {"exp_two_side", TimeGateMode::EXP_TWO_SIDE},
};

/// Gate kernel dropdown, with the kernels implemented by pathLengthImportance(). Returns true when the kernel changed.
inline bool renderTimeGateModeUI(Gui::Widgets& widget, TimeGateMode& mode)
{
    static const Gui::DropdownList kTimeGateModeList = {
        {(uint32_t)TimeGateMode::BOX, "Box"},
        {(uint32_t)TimeGateMode::TENT, "Tent"},
        {(uint32_t)TimeGateMode::GAUSSIAN, "Gaussian"},
        {(uint32_t)TimeGateMode::EXP, "Exponential (one-sided)"},
        {(uint32_t)TimeGateMode::EXP_TWO_SIDE, "Exponential (two-sided)"},
        {(uint32_t)TimeGateMode::COS, "Cos"},
        {(uint32_t)TimeGateMode::ALL, "All (no gating)"},
    };
    uint32_t value = (uint32_t)mode;
    if (!widget.dropdown("Gate kernel", kTimeGateModeList, value))
        return false;
    mode = (TimeGateMode)value;
    return true;
}
