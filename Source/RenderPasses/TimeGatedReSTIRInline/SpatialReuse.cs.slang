import RenderPasses.Shared.Shaders.Utils.TimeGate;
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
    float3 color = gSpatialReuse.resampleGate(pixel, 1, 0, gTimeCenter, newtonStats, mappingDistance);
    gSpatialReuse.gNewtonStatistics[pixel] += newtonStats;
    gSpatialReuse.gMappingDistance[pixel] += mappingDistance;
#else
    float3 color = gSpatialReuse.resampleGate(pixel, 1, 0, gTimeCenter);
#endif
    gSpatialReuse.gOutputColor[pixel] = float4(color / gTimeGateWindow, 1.f);
}
