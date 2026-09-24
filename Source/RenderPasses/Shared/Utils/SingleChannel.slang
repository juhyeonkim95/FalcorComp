/** The channel that single-channel rendering (USE_SINGLE_CHANNEL) keeps. SINGLE_CHANNEL is set by the host
 * (PathTracingConfig::SingleChannel): 0 = luminance, 1 = red, 2 = green, 3 = blue.
 */
#ifndef SINGLE_CHANNEL
#define SINGLE_CHANNEL 1
#endif

import Utils.Color.ColorHelpers;

float selectChannel(float3 value)
{
#if SINGLE_CHANNEL == 0
    return luminance(value);
#elif SINGLE_CHANNEL == 1
    return value.r;
#elif SINGLE_CHANNEL == 2
    return value.g;
#else
    return value.b;
#endif
}
