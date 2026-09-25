import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import Utils.Transient.TransientUtils;
import RenderPasses.Shared.Shaders.ReSTIR.SpatialReuse;

cbuffer CB
{
    SpatialReuse gSpatialReuse;
}

#if USE_SINGLE_CHANNEL
RWTexture3D<float> gTransientHistogram;
#else
RWTexture3D<float4> gTransientHistogram;
#endif

// Identical spatial RIS steps to the time-gated pass, applied to each bin.
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gSpatialReuse.gFrameDim)) return;
    float3 integratedRadiance = 0.f;
    for (uint bin = 0; bin < tbin; ++bin)
    {
        float gateCenter = tmin + (float(bin) + 0.5f) * tunit;
        float3 density = gSpatialReuse.resampleGate(pixel, tbin, bin, gateCenter) / tunit;
#if USE_SINGLE_CHANNEL
        gTransientHistogram[uint3(pixel, bin)] = selectChannel(density);
#else
        gTransientHistogram[uint3(pixel, bin)] = float4(density, 1.f);
#endif
        integratedRadiance += density * tunit;
    }
    gSpatialReuse.gOutputColor[pixel] = float4(integratedRadiance, 1.f);
}
