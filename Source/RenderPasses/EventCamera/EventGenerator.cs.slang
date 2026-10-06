/** Events from brightness change; see EventCamera.h. */
import Utils.Math.HashUtils;

cbuffer CB
{
    uint2 gFrameDim;
    uint gMode;         // 0: probabilistic, 1: accumulate.
    float gThreshold;   // C.
    uint gFrame;        // Event frame index, for the random numbers.
    uint gSeed;
    uint gClearResidual;
}

Texture2D<float> gDeltaL;
RWTexture2D<float> gResidual;
RWTexture2D<float> gEvents;

float uniform01(uint2 pixel)
{
    const uint h = jenkinsHash(jenkinsHash(jenkinsHash(pixel.x) ^ pixel.y) ^ jenkinsHash(gFrame ^ (gSeed * 0x9E3779B9u)));
    return float(h >> 8) * (1.f / 16777216.f);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    // A non-finite change makes no events (and does not latch into the residual).
    float deltaL = gDeltaL[pixel];
    if (!isfinite(deltaL))
        deltaL = 0.f;
    float events = 0.f;
    if (gMode == 0)
    {
        const float x = abs(deltaL) / gThreshold;
        const float n = floor(x) + (uniform01(pixel) < x - floor(x) ? 1.f : 0.f);
        events = deltaL < 0.f ? -n : n;
    }
    else
    {
        float residual = gClearResidual != 0 ? 0.f : gResidual[pixel];
        if (!isfinite(residual))
            residual = 0.f;
        residual += deltaL;
        events = trunc(residual / gThreshold);
        residual -= events * gThreshold;
        gResidual[pixel] = residual;
    }
    gEvents[pixel] = isfinite(events) ? events : 0.f;
}
