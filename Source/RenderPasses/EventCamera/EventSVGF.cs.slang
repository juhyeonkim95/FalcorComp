/** EventSVGF (Kim et al., EGSR 2026): SVGF on the demodulated primal and on the non-motion-aligned frame difference
 * from correlated sampling; see EventCamera.h. Kernels, per frame:
 * - reproject: demodulation, temporal accumulation of the primal and of the difference (Eq. 15-16), moments;
 * - atrous: one a-trous iteration, with the difference-aware edge-stopping weight (Eq. 12) for the difference;
 * - finalize: remodulation (Eq. 19) and the brightness change (Eq. 21).
 * Illumination textures hold (primal, difference, 0, variance of the primal).
 */
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;                // Frames since the last reset.
    float gAlpha;                    // Temporal blend factor of the illumination.
    float gMomentsAlpha;             // Temporal blend factor of the moments.
    uint gUseDemodulation;
    uint gUseTemporalAccumulation;   // Accumulate the difference over time.
    int gStepSize;                   // a-trous step.
    float gPhiColor;
    float gPhiNormal;
    uint gUseDifferenceAwareFiltering;
    uint gUseDenoisedDifference;     // Otherwise dI is the difference of the denoised primals.
    float gIntensityBias;            // Ie in L = log(Ie + I).
}

static const float kMinAlbedo = 0.001f;
static const int2 kBilinearOffsets[4] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1) };

// Inputs.
Texture2D gColor1; // Current frame, previous frame's seed.
Texture2D gColor2; // Current frame, current seed.
Texture2D gAlbedo;
Texture2D gEmission;
Texture2D gLinearZ;
Texture2D gNormal;
Texture2D gMotion;

// History, read (previous frame) and written (current frame).
Texture2D gPrevZN; // (linear z, dz, octahedral normal)
RWTexture2D<float4> gZN;
Texture2D gPrevFiltered;     // Feedback-tap illumination of frame t-1.
Texture2D gPrevPrevFiltered; // Feedback-tap illumination of frame t-2.
Texture2D<float2> gPrevMoments;
RWTexture2D<float2> gMoments;
Texture2D<float2> gPrevHistory; // (history length of the primal, consecutive frames with the same surface)
RWTexture2D<float2> gHistory;
Texture2D<float> gPrevReprojected; // Frame t-1's reprojection of the frame t-2 feedback, at the same pixel.
RWTexture2D<float> gReprojected;
RWTexture2D<float> gPrevIllumination2;         // Demodulated color2 of frame t-1; updated in place.
RWTexture2D<float4> gPrevAlbedoEmission;       // (albedo, emission, emitted luminance) of frame t-1, as remodulated; in place.
RWTexture2D<float> gPrevFinalIllumination;     // Denoised primal of frame t-1; updated in place.

// Reproject output, a-trous input/output.
RWTexture2D<float4> gIllumination;
Texture2D gAtrousInput;
RWTexture2D<float4> gAtrousOutput;

// Outputs.
Texture2D gFiltered;
RWTexture2D<float4> gDeltaI;
RWTexture2D<float> gDeltaL;
RWTexture2D<float> gDeltaIllumination;
RWTexture2D<float4> gPrimal;

/// (albedo, emission) luminance used to demodulate and remodulate; (1, 0) without demodulation.
float2 modulation(float3 albedo, float3 emission)
{
    if (!gUseDemodulation)
        return float2(1.0, 0.0);
    return float2(max(luminance(albedo), kMinAlbedo), luminance(emission));
}

float demodulate(float3 color, float2 albedoEmission)
{
    return (luminance(color) - albedoEmission.y) / albedoEmission.x;
}

/// Pixel `coord` of the previous frame shows the same surface: inside the image (one-pixel border excluded), depth
/// within 5% and normals within acos(0.9).
bool isConsistent(int2 coord, float z, float zPrev, float3 normal, float3 normalPrev)
{
    if (any(coord < int2(1, 1)) || any(coord > int2(gFrameDim) - int2(1, 1)))
        return false;
    if (abs(zPrev - z) > 0.05f * abs(z))
        return false;
    return dot(normal, normalPrev) >= 0.9f;
}

float computeWeight(float depthCenter, float depthP, float phiDepth, float3 normalCenter, float3 normalP, float phiNormal,
    float luminanceCenter, float luminanceP, float phiLuminance)
{
    const float weightNormal = pow(saturate(dot(normalCenter, normalP)), phiNormal);
    const float weightZ = (phiDepth == 0) ? 0.0f : abs(depthCenter - depthP) / phiDepth;
    const float weightLuminance = abs(luminanceCenter - luminanceP) / phiLuminance;
    return exp(0.0 - max(weightLuminance, 0.0) - max(weightZ, 0.0)) * weightNormal;
}

/// History of the previous frames at the reprojected position (bilinear over the consistent taps).
struct PrevData
{
    bool valid;           // Primal history.
    float illumination;   // Frame t-1 feedback primal.
    float2 moments;
    float historyLength;
    bool diffValid;       // Difference history: taps also consistent between t-1 and t-2.
    float difference;     // Frame t-1 feedback difference.
    float prevPrevIllumination; // Frame t-2 feedback primal.
};

PrevData loadPrevData(int2 pixel, float z, float3 normal)
{
    PrevData d = {};
    const float2 posPrev = float2(pixel) + gMotion[pixel].xy * float2(gFrameDim);
    const int2 nearestPrev = int2(posPrev + float2(0.5f, 0.5f));

    bool tapValid[4];
    bool tapDiffValid[4];
    bool anyValid = false;
    for (int k = 0; k < 4; k++)
    {
        const int2 loc = int2(posPrev) + kBilinearOffsets[k];
        const float4 zn = gPrevZN[loc];
        tapValid[k] = isConsistent(loc, z, zn.x, normal, oct_to_ndir_snorm(zn.zw));
        tapDiffValid[k] = tapValid[k] && gPrevHistory[loc].y >= 1;
        anyValid = anyValid || tapValid[k];
    }
    if (anyValid)
    {
        const float x = frac(posPrev.x);
        const float y = frac(posPrev.y);
        const float w[4] = { (1 - x) * (1 - y), x * (1 - y), (1 - x) * y, x * y };
        float sumW = 0;
        float sumWDiff = 0;
        for (int k = 0; k < 4; k++)
        {
            const int2 loc = int2(posPrev) + kBilinearOffsets[k];
            if (tapValid[k])
            {
                d.illumination += w[k] * gPrevFiltered[loc].r;
                d.moments += w[k] * gPrevMoments[loc];
                sumW += w[k];
            }
            if (tapDiffValid[k])
            {
                d.difference += w[k] * gPrevFiltered[loc].g;
                d.prevPrevIllumination += w[k] * gPrevPrevFiltered[loc].r;
                sumWDiff += w[k];
            }
        }
        d.valid = sumW >= 0.01;
        d.diffValid = d.valid && sumWDiff > 0.01;
        d.illumination = d.valid ? d.illumination / sumW : 0.0;
        d.moments = d.valid ? d.moments / sumW : float2(0, 0);
        d.difference = d.diffValid ? d.difference / sumWDiff : 0.0;
        d.prevPrevIllumination = d.diffValid ? d.prevPrevIllumination / sumWDiff : 0.0;
    }
    d.historyLength = d.valid ? gPrevHistory[nearestPrev].x : 0;
    return d;
}

[numthreads(16, 16, 1)]
void reproject(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const int2 pixel = dispatchThreadId.xy;
    if (any(pixel >= int2(gFrameDim)))
        return;

    // Pack depth and normal; the normal goes through the octahedral encoding, as the history does.
    const float4 zn = float4(gLinearZ[pixel].xy, ndir_to_oct_snorm(gNormal[pixel].xyz));
    gZN[pixel] = zn;
    const float z = zn.x;
    const float3 normal = oct_to_ndir_snorm(zn.zw);
    const float4 znPrev = gPrevZN[pixel];
    const bool sameSurface = isConsistent(pixel, z, znPrev.x, normal, oct_to_ndir_snorm(znPrev.zw));

    const PrevData prev = loadPrevData(pixel, z, normal);
    const float historyLength = min(32.0f, prev.valid ? prev.historyLength + 1.0f : 1.0f);
    const float sameSurfaceLength = (sameSurface && gFrameCount > 1) ? min(32.0f, gPrevHistory[pixel].y + 1.0f) : 0.0f;

    // Demodulated primal (I^1_t + I^2_t) / 2 and difference I^1_t - I^2_{t-1} (the pair sharing the seed r_{t-1}).
    const float3 emission = gEmission[pixel].rgb;
    const float2 albedoEmission = modulation(gAlbedo[pixel].rgb, emission);
    const float illumination1 = demodulate(gColor1[pixel].rgb, albedoEmission);
    const float illumination2 = demodulate(gColor2[pixel].rgb, albedoEmission);
    const float prevIllumination2 = gPrevIllumination2[pixel];
    gPrevIllumination2[pixel] = illumination2;
    const float primal = 0.5f * (illumination1 + illumination2);
    const float difference = illumination1 - prevIllumination2;

    // Primal: standard SVGF accumulation; alpha is raised while the history is short.
    const float alpha = prev.valid ? max(gAlpha, 1.0 / historyLength) : 1.0;
    const float alphaMoments = prev.valid ? max(gMomentsAlpha, 1.0 / historyLength) : 1.0;
    const float2 moments = lerp(prev.moments, float2(primal, primal * primal), alphaMoments);
    const float variance = max(0.f, moments.g - moments.r * moments.r);
    const float primalAccumulated = lerp(prev.illumination, primal, alpha);

    // Difference (Eq. 15-16): the previous difference at the reprojected position, plus frame t-2's feedback at that
    // position, minus frame t-2's feedback where frame t-1 reprojected this pixel.
    const float predicted = prev.difference + prev.prevPrevIllumination - gPrevReprojected[pixel];
    const float alphaDifference = (prev.valid && historyLength >= 2) ? max(gAlpha, 1.0 / (historyLength - 1)) : 1.0;
    const bool prevReprojected = gPrevHistory[pixel].x >= 2; // Frame t-1 reprojected this pixel: the third term exists.
    const bool accumulate = historyLength >= 3 && sameSurface && prev.diffValid && prevReprojected && gUseTemporalAccumulation;
    float differenceAccumulated = lerp(predicted, difference, accumulate ? alphaDifference : 1.0);
    if (luminance(emission) > 0 || gPrevAlbedoEmission[pixel].z > 0)
        differenceAccumulated = 0.0;

    gIllumination[pixel] = float4(primalAccumulated, differenceAccumulated, 0.0, variance);
    gMoments[pixel] = moments;
    gHistory[pixel] = float2(historyLength, sameSurfaceLength);
    gReprojected[pixel] = prev.illumination;
}

// 3x3 Gaussian of the variance around the pixel.
float filteredVariance(int2 pixel)
{
    const float kernel[2][2] = { { 1.0 / 4.0, 1.0 / 8.0 }, { 1.0 / 8.0, 1.0 / 16.0 } };
    float sum = 0.f;
    for (int yy = -1; yy <= 1; yy++)
        for (int xx = -1; xx <= 1; xx++)
            sum += gAtrousInput.Load(int3(pixel + int2(xx, yy), 0)).a * kernel[abs(xx)][abs(yy)];
    return sum;
}

[numthreads(16, 16, 1)]
void atrous(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const int2 pixel = dispatchThreadId.xy;
    if (any(pixel >= int2(gFrameDim)))
        return;

    const float4 center = gAtrousInput.Load(int3(pixel, 0));
    const float2 zCenter = gZN[pixel].xy;
    if (zCenter.x < 0)
    {
        // No valid depth: environment, not filtered.
        gAtrousOutput[pixel] = center;
        return;
    }
    const float3 nCenter = oct_to_ndir_snorm(gZN[pixel].zw);
    const float4 znCenterPrev = gPrevZN[pixel];
    const float3 nCenterPrev = oct_to_ndir_snorm(znCenterPrev.zw);

    const float phiLuminance = gPhiColor * sqrt(max(0.0, 1e-10 + filteredVariance(pixel)));
    const float phiDepth = max(zCenter.y, 1e-8) * gStepSize;
    const float phiDepthPrev = max(znCenterPrev.y, 1e-8) * gStepSize;
    const float kernelWeights[3] = { 1.0, 2.0 / 3.0, 1.0 / 6.0 };

    // The center pixel has weight 1.
    float sumW = 1.0;
    float sumWDiff = 1.0;
    float4 sum = center;
    for (int yy = -2; yy <= 2; yy++)
    {
        for (int xx = -2; xx <= 2; xx++)
        {
            const int2 p = pixel + int2(xx, yy) * gStepSize;
            if (any(p < int2(0, 0)) || any(p >= int2(gFrameDim)) || (xx == 0 && yy == 0))
                continue;
            const float kernel = kernelWeights[abs(xx)] * kernelWeights[abs(yy)];
            const float4 illuminationP = gAtrousInput.Load(int3(p, 0));
            const float4 znP = gZN[p];
            const float4 znPPrev = gPrevZN[p];
            const float distance = length(float2(xx, yy));

            // Primal: current-frame features.
            const float wCurr = computeWeight(zCenter.x, znP.x, phiDepth * distance, nCenter, oct_to_ndir_snorm(znP.zw),
                gPhiNormal, center.r, illuminationP.r, phiLuminance);
            // Difference (Eq. 12): also the previous frame's features, and the difference itself.
            float wPrev = 1.0;
            if (gUseDifferenceAwareFiltering)
                wPrev = computeWeight(znCenterPrev.x, znPPrev.x, phiDepthPrev * distance, nCenterPrev,
                    oct_to_ndir_snorm(znPPrev.zw), gPhiNormal, center.g, illuminationP.g, phiLuminance * 0.5);

            const float w = wCurr * kernel;
            const float wDiff = wCurr * wPrev * kernel;
            sumW += w;
            sumWDiff += wDiff;
            // The variance is weighted with the squared weights.
            sum += float4(w, wDiff, 0.0, w * w) * illuminationP;
        }
    }
    gAtrousOutput[pixel] = float4(sum.r / sumW, sum.g / sumWDiff, 0.0, sum.a / (sumW * sumW));
}

[numthreads(16, 16, 1)]
void finalize(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const int2 pixel = dispatchThreadId.xy;
    if (any(pixel >= int2(gFrameDim)))
        return;

    const float4 zn = gZN[pixel];
    const float4 znPrev = gPrevZN[pixel];
    // (albedo, emission) for remodulation, and the luminance of the emission (to detect emitters).
    const float emitted = luminance(gEmission[pixel].rgb);
    const float2 albedoEmission = modulation(gAlbedo[pixel].rgb, gEmission[pixel].rgb);
    const float albedo = albedoEmission.x;
    const float emission = albedoEmission.y;
    const float3 prev = gPrevAlbedoEmission[pixel].xyz;
    const float prevAlbedo = prev.x;
    const float prevEmission = prev.y;
    const float prevEmitted = prev.z;
    const float illumination = gFiltered[pixel].r;
    const float illuminationDifference = gFiltered[pixel].g;
    const float prevIllumination = gPrevFinalIllumination[pixel];
    gPrevFinalIllumination[pixel] = illumination;
    gPrevAlbedoEmission[pixel] = float4(albedo, emission, emitted, 0.0);

    float deltaIllumination = 0.0;
    float deltaI = 0.0;
    float deltaL = 0.0;
    if (gFrameCount > 0)
    {
        // Same surface in both frames (and not an emitter in both): the denoised difference; otherwise the
        // difference of the denoised primals.
        const bool sameSurface = isConsistent(pixel, zn.x, znPrev.x, oct_to_ndir_snorm(zn.zw), oct_to_ndir_snorm(znPrev.zw)) &&
            (emitted == 0 || prevEmitted == 0);
        deltaIllumination = (sameSurface && gUseDenoisedDifference) ? illuminationDifference : illumination - prevIllumination;
        // Eq. 19 and 21.
        deltaI = albedo * deltaIllumination + (albedo - prevAlbedo) * prevIllumination + (emission - prevEmission);
        // The current intensity prevI + dI is clamped at 0, so dL is bounded by the intensity bias.
        const float prevI = prevAlbedo * prevIllumination + prevEmission;
        deltaL = log(gIntensityBias + max(prevI + deltaI, 0.0)) - log(gIntensityBias + max(prevI, 0.0));
    }
    gDeltaIllumination[pixel] = deltaIllumination;
    gDeltaI[pixel] = float4(deltaI, deltaI, deltaI, 0.0);
    gDeltaL[pixel] = deltaL;
    const float3 primal = gUseDemodulation ? gAlbedo[pixel].rgb * illumination + gEmission[pixel].rgb : float3(illumination);
    gPrimal[pixel] = float4(primal, 1.0);
}
