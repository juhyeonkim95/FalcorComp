import RenderPasses.Shared.Shaders.Utils.TimeGate;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import RenderPasses.Shared.Shaders.ReSTIR.SpatialReuse;

cbuffer CB
{
    SpatialReuse gSpatialReuse;
}

RWTexture3D<HistogramTexel> gTransientHistogram;

// Identical spatial RIS steps to the time-gated pass, applied to each bin.
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gSpatialReuse.gFrameDim)) return;
    float3 integratedRadiance = 0.f;
    for (uint bin = 0; bin < gTimeBin; ++bin)
    {
        float3 density = gSpatialReuse.resampleGate(pixel, gTimeBin, bin, binCenter(bin)) / gBinWidth;
        gTransientHistogram[uint3(pixel, bin)] = toHistogramTexel(density);
        integratedRadiance += density * gBinWidth;
    }
    gSpatialReuse.gOutputColor[pixel] = float4(integratedRadiance, 1.f);
}
