/** Frame-to-frame difference for event cameras; see EventCamera.h. */

cbuffer CB
{
    uint2 gFrameDim;
    uint gSubframe;       // Index of this execution within the event frame.
    uint gSubframes;      // Executions per event frame.
    uint gCorrelated;     // color2 is the render with the current seed.
    uint gHasHistory;     // The previous event frame exists.
    float gIntensityBias; // Ie in L = log(Ie + I).
}

Texture2D<float4> gColor1;
Texture2D<float4> gColor2;
RWTexture2D<float4> gSum1;
RWTexture2D<float4> gSum2;
RWTexture2D<float4> gHistory;
RWTexture2D<float4> gDeltaI;
RWTexture2D<float> gDeltaL;
RWTexture2D<float4> gPrimal;

float luminance(float3 c)
{
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 sum1 = gColor1[pixel].rgb;
    float3 sum2 = gCorrelated ? gColor2[pixel].rgb : sum1;
    if (gSubframe > 0)
    {
        sum1 += gSum1[pixel].rgb;
        if (gCorrelated)
            sum2 += gSum2[pixel].rgb;
    }
    if (gSubframe + 1 < gSubframes)
    {
        gSum1[pixel] = float4(sum1, 0.f);
        if (gCorrelated)
            gSum2[pixel] = float4(sum2, 0.f);
        return;
    }

    // The event frame is complete. color1 pairs with the history: same seed (correlated) or the previous render.
    const float3 newer = sum1 / float(gSubframes);
    const float3 current = gCorrelated ? sum2 / float(gSubframes) : newer;
    const float4 history = gHistory[pixel]; // alpha: the history holds a sample.
    const float3 older = history.rgb;
    // A non-finite sample (NaN or Inf from the renderer) gives no difference and leaves the history as it was.
    const bool finite = all(isfinite(newer)) && all(isfinite(current));

    float3 deltaI = float3(0.f);
    float deltaL = 0.f;
    if (gHasHistory && finite && history.a > 0.f)
    {
        deltaI = newer - older;
        deltaL = log(gIntensityBias + max(luminance(newer), 0.f)) - log(gIntensityBias + max(luminance(older), 0.f));
    }
    gDeltaI[pixel] = float4(deltaI, 0.f);
    gDeltaL[pixel] = deltaL;
    gPrimal[pixel] = float4(finite ? 0.5f * (newer + current) : older, 1.f);
    if (finite)
        gHistory[pixel] = float4(current, 1.f);
}
