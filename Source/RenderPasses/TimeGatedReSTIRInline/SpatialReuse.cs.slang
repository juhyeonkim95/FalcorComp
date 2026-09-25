import Utils.Transient.TransientUtils;
import RenderPasses.Shared.Shaders.ReSTIR.SpatialReuse;

cbuffer CB
{
    SpatialReuse gSpatialReuse;
}

// A time gate is the single-bin case of the shared spatial reuse.
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gSpatialReuse.gFrameDim)) return;
#if DEBUG_NEWTON_ITERATIONS
    uint4 newtonStats;
    float2 mappingDistance;
    float3 color = gSpatialReuse.resampleGate(pixel, 1, 0, tcurr, newtonStats, mappingDistance);
    gSpatialReuse.gNewtonStatistics[pixel] += newtonStats;
    gSpatialReuse.gMappingDistance[pixel] += mappingDistance;
#else
    float3 color = gSpatialReuse.resampleGate(pixel, 1, 0, tcurr);
#endif
    gSpatialReuse.gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
}
