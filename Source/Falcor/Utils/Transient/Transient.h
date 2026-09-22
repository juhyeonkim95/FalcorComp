#pragma once
#include "Falcor.h"

using namespace Falcor;

enum class TimeGateMode
{
    ALL = 0,
    BOX = 1,
    TENT = 2,
    COS = 3,
    EXP = 4,
    GAUSSIAN = 5,
    EPANECHNIKOV = 6,
    SAWTOOTH = 7,
    PERLIN = 8
};


static const std::unordered_map<std::string, TimeGateMode> TimeGateModeTable = {
    {"all", TimeGateMode::ALL},
    {"box", TimeGateMode::BOX},
    {"tent", TimeGateMode::TENT},
    {"cos", TimeGateMode::COS},
    {"exp", TimeGateMode::EXP},
    {"gaussian", TimeGateMode::GAUSSIAN},
    {"epanechnikov", TimeGateMode::EPANECHNIKOV},
    {"sawtooth", TimeGateMode::SAWTOOTH},
    {"perlin", TimeGateMode::PERLIN}
};


// class TransientInterface
// {
// protected:
//     void parse_Properties(const Properties& props);
//     // Time Gate Data
//     float mTimeGateWindow_temp = 0.05f;
//     TimeGateMode mTimeGateMode_temp = TimeGateMode::BOX;
//     float mTimeMin_temp = 9.0f;
//     float mTimeMax_temp = 12.0f;
//     uint mTimeBin_temp = 512;
// };
