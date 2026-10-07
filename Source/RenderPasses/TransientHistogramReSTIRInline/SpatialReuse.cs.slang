import RenderPasses.Shared.Shaders.Utils.TimeGate;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import RenderPasses.Shared.Shaders.ReSTIR.SpatialReuse;

cbuffer CB
{
    SpatialReuse gSpatialReuse;
}

RWTexture3D<HistogramTexel> gTransientHistogram;

// Identical spatial RIS steps to the time-gated pass, applied to each bin.
// Bins outer, neighbors inner (resampleGate reloads the primary hits for every bin). This is faster than looping
// over neighbors outside and bins inside: the destination reservoir and the central suffix stay in registers for one
// bin, instead of a read-modify-write of every bin's reservoir in memory per neighbor and a reload of the central
// suffix per (neighbor, bin). The primary-hit loads cost little next to the shifts.
// With SPATIAL_REUSE_PAIRS this resamples the bins of the current chunk from the records of SpatialReusePairs.cs.slang,
// and the integrated radiance continues the previous chunks' sum (bin order, as without chunks).
[numthreads(8, 4, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gSpatialReuse.gFrameDim)) return;
#if SPATIAL_REUSE_PAIRS
    const uint firstBin = gSpatialReuse.pairFirstBin;
    const uint endBin = firstBin + gSpatialReuse.pairBinCount;
    float3 integratedRadiance = firstBin == 0 ? float3(0.f) : gSpatialReuse.gOutputColor[pixel].xyz;
#else
    const uint firstBin = 0;
    const uint endBin = gTimeBin;
    float3 integratedRadiance = 0.f;
#endif
    for (uint bin = firstBin; bin < endBin; ++bin)
    {
#if SPATIAL_REUSE_PAIRS
        float3 density = gSpatialReuse.resampleFromPairs(pixel, gTimeBin, bin, binCenter(bin)) / gBinWidth;
#else
        float3 density = gSpatialReuse.resampleGate(pixel, gTimeBin, bin, binCenter(bin)) / gBinWidth;
#endif
        // Only the last iteration's histogram is final; earlier iterations' would be overwritten.
        if (gSpatialReuse.lastIteration) gTransientHistogram[uint3(pixel, bin)] = toHistogramTexel(density);
        integratedRadiance += density * gBinWidth;
    }
    gSpatialReuse.gOutputColor[pixel] = float4(integratedRadiance, 1.f);
}
