#include "Transient.h"

namespace
{
const char kTimeGateWindow[] = "timeGateWindow";
const char kTimeGateMode[] = "timeGateMode";
const char kTimeMin[] = "timeMin";
const char kTimeMax[] = "timeMax";
const char kTimeBin[] = "timeBin";
}

void TransientInterface::parse_Properties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kTimeGateMode)
            mTimeGateMode_temp = TimeGateModeTable[value];
        else if (key == kTimeGateWindow)
            mTimeGateWindow_temp = value;
        else if (key == kTimeMin)
            mTimeMin_temp = value;
        else if (key == kTimeMax)
            mTimeMax_temp = value;
        else if (key == kTimeBin)
            mTimeBin_temp = value;
        else
            logWarning("Unknown property '{}' in MinimalTransientReSTIR properties.", key);
    }
}