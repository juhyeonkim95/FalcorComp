/** Continuous-wave time-of-flight modulation: a path of optical length l is weighted by the waveform w (Waveform.slang)
    at t = l / wavelength - phase periods, or by 0.5 w + 0.5 with unsigned modulation, with a phase per color channel
    (phase + phaseShift). The host sets the ContinuousWave constants (Shared/Host/Configs/ContinuousWaveConfig.h).
*/
import RenderPasses.Shared.Shaders.Utils.Waveform;

cbuffer ContinuousWave
{
    float gModulationWavelength; // Path length of one period.
    float3 gModulationPhase;     // Sensor phase offset, in periods, per color channel.
    uint gWaveform;              // WAVEFORM_* (Waveform.slang).
    uint gUnsignedModulation;    // Weight 0.5 w + 0.5 instead of w.
};

/// Position of a path of optical length `pathLength` in the modulation, in periods, per color channel.
float3 modulationPeriods(float pathLength)
{
    return pathLength / gModulationWavelength - gModulationPhase;
}

/// Weight of a path of optical length `pathLength`, per color channel.
float3 modulationWeight(float pathLength)
{
    float3 t = modulationPeriods(pathLength);
    float3 weight = float3(evalWaveform(gWaveform, t.x), evalWaveform(gWaveform, t.y), evalWaveform(gWaveform, t.z));
    return gUnsignedModulation != 0 ? 0.5f * weight + 0.5f : weight;
}

/// Change of path length that flips the sign of the waveform for a path of length `pathLength`
/// (antitheticWaveformOffset in Waveform.slang, as a length), in the red channel. `u` in [0,1) picks one of the two
/// inverse offsets. Half a period, which every waveform but the sawtooth uses, flips all channels whatever their phase.
float antitheticPathLengthOffset(float pathLength, float u)
{
    return antitheticWaveformOffset(gWaveform, modulationPeriods(pathLength).x, u) * gModulationWavelength;
}
