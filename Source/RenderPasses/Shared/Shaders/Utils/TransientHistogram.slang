/** Transient histogram: gTimeBin bins of width gBinWidth over the path lengths [gTimeMin, gTimeMax). The host sets the
    TransientHistogram constants (TransientHistogramConfig).
*/
import RenderPasses.Shared.Shaders.Utils.SingleChannel;

cbuffer TransientHistogram
{
    uint gTimeBin;
    float gTimeMin;
    float gTimeMax;
    float gBinWidth;
};

/// Path length at the center of bin `bin`.
float binCenter(uint bin)
{
    return gTimeMin + (float(bin) + 0.5f) * gBinWidth;
}

/// Texel of the histogram output (RWTexture3D<HistogramTexel>): the channel that USE_SINGLE_CHANNEL keeps, or RGB
/// with an alpha of one.
#if USE_SINGLE_CHANNEL
typealias HistogramTexel = float;
HistogramTexel toHistogramTexel(float3 value) { return selectChannel(value); }
#else
typealias HistogramTexel = float4;
HistogramTexel toHistogramTexel(float3 value) { return float4(value, 1.f); }
#endif
