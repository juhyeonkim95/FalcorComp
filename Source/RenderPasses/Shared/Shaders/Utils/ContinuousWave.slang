/** Continuous-wave time-of-flight modulation: a path of optical length l is weighted by the waveform w (Waveform.slang)
    at t = l / wavelength - phase periods, or by 0.5 w + 0.5 with unsigned modulation. The host sets the
    ContinuousWave constants (Shared/Host/Configs/ContinuousWaveConfig.h).
*/
import RenderPasses.Shared.Shaders.Utils.Waveform;

cbuffer ContinuousWave
{
    float gModulationWavelength; // Path length of one period.
    float gModulationPhase;      // Sensor phase offset, in periods.
    uint gWaveform;              // WAVEFORM_* (Waveform.slang).
    uint gUnsignedModulation;    // Weight 0.5 w + 0.5 instead of w.
};

/// Position of a path of optical length `pathLength` in the modulation, in periods.
float modulationPeriods(float pathLength)
{
    return pathLength / gModulationWavelength - gModulationPhase;
}

/// Weight of a path of optical length `pathLength`.
float modulationWeight(float pathLength)
{
    float weight = evalWaveform(gWaveform, modulationPeriods(pathLength));
    return gUnsignedModulation != 0 ? 0.5f * weight + 0.5f : weight;
}

/// Change of path length that flips the sign of the waveform for a path of length `pathLength`
/// (antitheticWaveformOffset in Waveform.slang, as a length). `u` in [0,1) picks one of the two inverse offsets.
float antitheticPathLengthOffset(float pathLength, float u)
{
    return antitheticWaveformOffset(gWaveform, modulationPeriods(pathLength), u) * gModulationWavelength;
}
