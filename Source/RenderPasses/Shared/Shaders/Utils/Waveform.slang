/** Periodic waveforms of the continuous-wave time-of-flight modulation and the projector's periodic pattern.
    The host picks them with Shared/Host/Configs/Waveform.h.
*/
#include "Utils/Math/MathConstants.slangh"

#define WAVEFORM_COS 0
#define WAVEFORM_TRIANGLE 1
#define WAVEFORM_BOX 2
#define WAVEFORM_SAWTOOTH 3

/// Zero-mean waveform in [-1, 1] at `t` periods. cos, triangle and box peak at t = 0; the sawtooth rises from -1
/// to 1 over each period.
float evalWaveform(uint waveform, float t)
{
    float s = frac(t);
    float centered = s < 0.5f ? s : s - 1.f; // [-1/2, 1/2)
    switch (waveform)
    {
    case WAVEFORM_COS:
        return cos(M_2PI * s);
    case WAVEFORM_TRIANGLE:
        return 1.f - 4.f * abs(centered);
    case WAVEFORM_BOX:
        return abs(centered) < 0.25f ? 1.f : -1.f;
    default: // WAVEFORM_SAWTOOTH
        return 2.f * s - 1.f;
    }
}

/// Offset, in periods, from `t` to a point where the waveform has the opposite value.
/// cos, triangle and box satisfy w(t + 1/2) = -w(t): the offset is +1/2 or -1/2, picked by `u` with equal
/// probability, and the two offsets are inverses of each other. The sawtooth uses the mirror t -> 1 - t, its own
/// inverse, with the offset taken in [-1/2, 1/2].
float antitheticWaveformOffset(uint waveform, float t, float u)
{
    if (waveform != WAVEFORM_SAWTOOTH)
        return u < 0.5f ? 0.5f : -0.5f;
    float offset = 1.f - 2.f * frac(t);
    if (offset > 0.5f)
        offset -= 1.f;
    else if (offset < -0.5f)
        offset += 1.f;
    return offset;
}

/// Offset, in periods, from `t` to its mirror image within the period, where the waveform has the opposite value:
/// about t = 1/4 and 3/4 (t -> 1/2 - t) for cos, triangle and box, and about t = 1/2 (t -> 1 - t) for the sawtooth.
/// A mirror is its own inverse.
float mirrorWaveformOffset(uint waveform, float t)
{
    float s = frac(t);
    if (waveform == WAVEFORM_SAWTOOTH)
        return 1.f - 2.f * s;
    return (s > 0.25f ? 1.5f - s : -0.5f - s) - s;
}
