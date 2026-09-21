import Utils.Math.MathHelpers;
import Utils.Transient.TransientUtils;
import Reservoirs;
import LoadShadingData;

struct EvaluateFinalSamples
{
    // Reservoir Struct
    StructuredBuffer<Reservoir> currReservoirs;

    // outputs
    RWTexture2D<float4> gOutputColor;
    uint2 gFrameDim;

    uint getLinearizedPixel(uint2 pixel){
        return pixel.y * gFrameDim.x + pixel.x;
    }

    float3 process(uint2 pixel){
        const uint linearizedPixel = getLinearizedPixel(pixel);
        Reservoir curr_reservoir = currReservoirs[linearizedPixel];
        float3 outColor = curr_reservoir.W * curr_reservoir.f;
        return outColor;
    }
}

cbuffer CB
{
    EvaluateFinalSamples gEvaluateFinalSamples;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gEvaluateFinalSamples.gFrameDim)) return;
    float3 color = gEvaluateFinalSamples.process(pixel);
    gEvaluateFinalSamples.gOutputColor[pixel] = float4(color / min(1.0, time_gate_window), 1.f);
}
