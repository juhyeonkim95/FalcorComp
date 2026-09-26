/** Adds the primary-hit direct lighting that InitialSampleGeneration computed (gDirectColor, already divided by
 * the gate width) to the output of the last ReSTIR pass. Runs only with computeDirect.
 */
cbuffer CB
{
    uint2 gFrameDim;
}

Texture2D<float4> gDirectColor;
RWTexture2D<float4> gOutputColor;

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] += float4(gDirectColor[pixel].rgb, 0.f);
}
