/** EventSVGF (Kim et al., EGSR 2026): SVGF on the demodulated primal and on the non-motion-aligned frame difference
 * from correlated sampling; see EventCamera.h. Kernels, per frame:
 * - reproject: demodulation, temporal accumulation of the primal and of the difference (Eq. 15-16), moments;
 * - filterMoments: while a history is short, the variance (and value) estimated spatially, as SVGF does;
 * - atrous: one a-trous iteration, with the difference-aware edge-stopping weight (Eq. 12) for the difference;
 * - finalize: remodulation (Eq. 19) and the brightness change (Eq. 21).
 * Illumination textures hold (primal, difference, variance of the difference, variance of the primal).
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
    uint gUseDifferenceVariance;     // The difference's own variance (else the primal's / 4) sets its edge-stopping width.
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
Texture2D gPrevMoments; // (primal: mean, second moment; difference: mean, second moment)
RWTexture2D<float4> gMoments;
Texture2D gPrevHistory; // (history length of the primal, consecutive frames with the same surface, of the difference)
RWTexture2D<float4> gHistory;
Texture2D<float> gPrevReprojected; // Frame t-1's reprojection of the frame t-2 feedback, at the same pixel.
RWTexture2D<float> gReprojected;
RWTexture2D<float> gPrevIllumination2;         // Demodulated color2 of frame t-1; updated in place.
RWTexture2D<float4> gPrevAlbedoEmission;       // (albedo, emission, emitted luminance) of frame t-1, as remodulated; in place.
RWTexture2D<float> gPrevFinalIllumination;     // Denoised primal of frame t-1; updated in place.
RWTexture2D<float> gEmitterOut;                // 1 where the pixel shows an emitter in the current or the previous frame.
Texture2D<float> gEmitter;                     // The same, read by the filters.

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
    if (gUseDemodulation == 0)
        return float2(1.0, 0.0);
    return float2(max(luminance(albedo), kMinAlbedo), luminance(emission));
}

float demodulate(float3 color, float2 albedoEmission)
{
    return (luminance(color) - albedoEmission.y) / albedoEmission.x;
}

/// The pixel shows an emitter in the current or the previous frame (after reproject).
bool isEmitter(int2 pixel)
{
    return gEmitter[pixel] > 0.5f;
}

/// The previous frame's sample at the same pixel shows the same surface: depth within 5% and normals within acos(0.9).
bool isSameSurface(float z, float zPrev, float3 normal, float3 normalPrev)
{
    if (abs(zPrev - z) > 0.05f * abs(z))
        return false;
    return dot(normal, normalPrev) >= 0.9f;
}

/// Pixel `coord` of the previous frame, reprojected, shows the same surface: inside the image (one-pixel border
/// excluded, where reprojection is unreliable) and isSameSurface().
bool isConsistent(int2 coord, float z, float zPrev, float3 normal, float3 normalPrev)
{
    if (any(coord < int2(1, 1)) || any(coord > int2(gFrameDim) - int2(1, 1)))
        return false;
    return isSameSurface(z, zPrev, normal, normalPrev);
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
    float2 differenceMoments;
    float differenceHistoryLength;
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
                d.moments += w[k] * gPrevMoments[loc].xy;
                sumW += w[k];
            }
            if (tapDiffValid[k])
            {
                d.difference += w[k] * gPrevFiltered[loc].g;
                d.prevPrevIllumination += w[k] * gPrevPrevFiltered[loc].r;
                d.differenceMoments += w[k] * gPrevMoments[loc].zw;
                sumWDiff += w[k];
            }
        }
        d.valid = sumW >= 0.01;
        d.diffValid = d.valid && sumWDiff > 0.01;
        d.illumination = d.valid ? d.illumination / sumW : 0.0;
        d.moments = d.valid ? d.moments / sumW : float2(0, 0);
        d.differenceMoments = d.diffValid ? d.differenceMoments / sumWDiff : float2(0, 0);
        d.difference = d.diffValid ? d.difference / sumWDiff : 0.0;
        d.prevPrevIllumination = d.diffValid ? d.prevPrevIllumination / sumWDiff : 0.0;
    }
    d.historyLength = d.valid ? gPrevHistory[nearestPrev].x : 0;
    d.differenceHistoryLength = d.diffValid ? gPrevHistory[nearestPrev].z : 0;
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
    const bool sameSurface = isSameSurface(z, znPrev.x, normal, oct_to_ndir_snorm(znPrev.zw));

    const PrevData prev = loadPrevData(pixel, z, normal);
    const float historyLength = min(32.0f, prev.valid ? prev.historyLength + 1.0f : 1.0f);
    const float sameSurfaceLength = (sameSurface && gFrameCount > 1) ? min(32.0f, gPrevHistory[pixel].y + 1.0f) : 0.0f;

    // Demodulated primal (I^1_t + I^2_t) / 2 and difference I^1_t - I^2_{t-1} (the pair sharing the seed r_{t-1}).
    const float3 emission = gEmission[pixel].rgb;
    const float2 albedoEmission = modulation(gAlbedo[pixel].rgb, emission);
    float illumination1 = demodulate(gColor1[pixel].rgb, albedoEmission);
    float illumination2 = demodulate(gColor2[pixel].rgb, albedoEmission);
    // A non-finite sample (NaN or Inf from the renderer) would spread through the filter and stay in the history: use
    // the history's value instead.
    const float fallback = prev.valid ? prev.illumination : 0.f;
    if (!isfinite(illumination1))
        illumination1 = fallback;
    if (!isfinite(illumination2))
        illumination2 = fallback;
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
    const bool prevReprojected = gPrevHistory[pixel].x >= 2; // Frame t-1 reprojected this pixel: the third term exists.
    const bool accumulate = historyLength >= 3 && sameSurface && prev.diffValid && prevReprojected && gUseTemporalAccumulation != 0;
    // The difference exists from the second frame on: its samples number historyLength - 1.
    const float alphaDifference = (prev.valid && historyLength >= 2) ? max(gAlpha, 1.0 / (historyLength - 1)) : 1.0;
    // Frames the difference has been accumulated over, for its moments.
    const float differenceHistoryLength = accumulate ? min(32.0f, prev.differenceHistoryLength + 1.0f) : 1.0f;
    float differenceAccumulated = lerp(predicted, difference, accumulate ? alphaDifference : 1.0);

    // Moments of the raw difference, accumulated like the difference.
    const float alphaDifferenceMoments = accumulate ? max(gMomentsAlpha, 1.0 / differenceHistoryLength) : 1.0;
    float2 differenceMoments = lerp(prev.differenceMoments, float2(difference, difference * difference), alphaDifferenceMoments);
    const bool emitter = luminance(emission) > 0 || gPrevAlbedoEmission[pixel].z > 0;
    gEmitterOut[pixel] = emitter ? 1.0f : 0.0f;
    if (emitter)
    {
        differenceAccumulated = 0.0;
        differenceMoments = float2(0.0);
    }
    const float differenceVariance = max(0.f, differenceMoments.y - differenceMoments.x * differenceMoments.x);

    float4 accumulated = float4(primalAccumulated, differenceAccumulated, differenceVariance, variance);
    float4 allMoments = float4(moments, differenceMoments);
    // Overflow (e.g. a huge sample squared): restart from this frame's values.
    if (!all(isfinite(accumulated)) || !all(isfinite(allMoments)))
    {
        accumulated = float4(primal, emitter ? 0.f : difference, 0.f, 0.f);
        allMoments = float4(primal, 0.f, 0.f, 0.f);
    }
    gIllumination[pixel] = accumulated;
    gMoments[pixel] = allMoments;
    gHistory[pixel] = float4(historyLength, sameSurfaceLength, differenceHistoryLength, 0.0);
    gReprojected[pixel] = prev.illumination;
}

// While the primal's or the difference's history is shorter than 4 frames, its temporal variance is unreliable: 0 right
// after a restart, which would stop the a-trous filter. As SVGF's filterMoments, estimate the variance (and the value)
// spatially over a 7x7 cross-bilateral neighborhood, with a boost for the first frames. The difference only takes
// neighbors that are no emitter and show the same surfaces in the previous frame too.
[numthreads(16, 16, 1)]
void filterMoments(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    const int2 pixel = dispatchThreadId.xy;
    if (any(pixel >= int2(gFrameDim)))
        return;

    const float4 center = gAtrousInput.Load(int3(pixel, 0));
    const float4 history = gHistory[pixel];
    const bool primalShort = history.x < 4.0;
    const bool differenceShort = history.z < 4.0 && !isEmitter(pixel);
    const float2 zCenter = gZN[pixel].xy;
    if ((!primalShort && !differenceShort) || zCenter.x < 0)
    {
        gAtrousOutput[pixel] = center;
        return;
    }
    const float3 nCenter = oct_to_ndir_snorm(gZN[pixel].zw);
    const float4 znCenterPrev = gPrevZN[pixel];
    const float3 nCenterPrev = oct_to_ndir_snorm(znCenterPrev.zw);
    const float phiDepth = max(zCenter.y, 1e-8) * 3.0;
    const float phiDepthPrev = max(znCenterPrev.y, 1e-8) * 3.0;

    float sumW = 0.0;
    float sumWDiff = 0.0;
    float2 sumValue = float2(0.0);
    float4 sumMoments = float4(0.0);
    for (int yy = -3; yy <= 3; yy++)
    {
        for (int xx = -3; xx <= 3; xx++)
        {
            const int2 p = pixel + int2(xx, yy);
            if (any(p < int2(0, 0)) || any(p >= int2(gFrameDim)))
                continue;
            const float4 illuminationP = gAtrousInput.Load(int3(p, 0));
            const float4 momentsP = gMoments[p];
            const float4 znP = gZN[p];
            const float distance = length(float2(xx, yy));
            const float w = computeWeight(zCenter.x, znP.x, phiDepth * distance, nCenter, oct_to_ndir_snorm(znP.zw),
                gPhiNormal, center.r, illuminationP.r, gPhiColor);
            sumW += w;
            sumValue.x += w * illuminationP.r;
            sumMoments.xy += w * momentsP.xy;
            // The previous frame's surfaces too (the difference pairs the two frames), without a luminance term.
            const float4 znPPrev = gPrevZN[p];
            const float wPrev = isEmitter(p) ? 0.0 : computeWeight(znCenterPrev.x, znPPrev.x, phiDepthPrev * distance,
                nCenterPrev, oct_to_ndir_snorm(znPPrev.zw), gPhiNormal, 0.0, 0.0, 1.0);
            sumWDiff += w * wPrev;
            sumValue.y += w * wPrev * illuminationP.g;
            sumMoments.zw += w * wPrev * momentsP.zw;
        }
    }
    float4 result = center;
    if (primalShort)
    {
        sumW = max(sumW, 1e-6f);
        const float2 m = sumMoments.xy / sumW;
        result.r = sumValue.x / sumW;
        result.a = max(0.0, m.y - m.x * m.x) * 4.0 / max(history.x, 1.0);
    }
    if (differenceShort && sumWDiff > 1e-6f)
    {
        const float2 m = sumMoments.zw / sumWDiff;
        result.g = sumValue.y / sumWDiff;
        result.b = max(0.0, m.y - m.x * m.x) * 4.0 / max(history.z, 1.0);
    }
    gAtrousOutput[pixel] = result;
}

// 3x3 Gaussian of the variances (difference in .x, primal in .y) around the pixel.
float2 filteredVariance(int2 pixel)
{
    const float kernel[2][2] = { { 1.0 / 4.0, 1.0 / 8.0 }, { 1.0 / 8.0, 1.0 / 16.0 } };
    float2 sum = 0.f;
    for (int yy = -1; yy <= 1; yy++)
        for (int xx = -1; xx <= 1; xx++)
            sum += gAtrousInput.Load(int3(pixel + int2(xx, yy), 0)).ba * kernel[abs(xx)][abs(yy)];
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

    const float2 variance = filteredVariance(pixel);
    const float phiLuminance = gPhiColor * sqrt(max(0.0, 1e-10 + variance.y));
    const float phiDifference = gUseDifferenceVariance != 0 ? gPhiColor * sqrt(max(0.0, 1e-10 + variance.x)) : phiLuminance * 0.5;
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
            if (gUseDifferenceAwareFiltering != 0)
                wPrev = computeWeight(znCenterPrev.x, znPPrev.x, phiDepthPrev * distance, nCenterPrev,
                    oct_to_ndir_snorm(znPPrev.zw), gPhiNormal, center.g, illuminationP.g, phiDifference);
            // Emitters carry no difference (finalize uses the primal difference there): leave them out.
            if (isEmitter(p))
                wPrev = 0.0;

            const float w = wCurr * kernel;
            const float wDiff = wCurr * wPrev * kernel;
            sumW += w;
            sumWDiff += wDiff;
            // The variances are weighted with the squared weights.
            sum += float4(w, wDiff, wDiff * wDiff, w * w) * illuminationP;
        }
    }
    gAtrousOutput[pixel] = float4(sum.r / sumW, sum.g / sumWDiff, sum.b / (sumWDiff * sumWDiff), sum.a / (sumW * sumW));
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
        // Same surface in both frames and no emitter in either: the denoised difference; otherwise the difference
        // of the denoised primals (exact for the remodulated primals).
        const bool sameSurface = isSameSurface(zn.x, znPrev.x, oct_to_ndir_snorm(zn.zw), oct_to_ndir_snorm(znPrev.zw)) &&
            emitted == 0 && prevEmitted == 0;
        deltaIllumination = (sameSurface && gUseDenoisedDifference != 0) ? illuminationDifference : illumination - prevIllumination;
        // Eq. 19 and 21.
        deltaI = albedo * deltaIllumination + (albedo - prevAlbedo) * prevIllumination + (emission - prevEmission);
        const float prevI = prevAlbedo * prevIllumination + prevEmission;
        // A denoised difference that makes the current intensity negative is noise: use the difference of the denoised
        // primals, whose current intensity is the current primal. (Clamping it at 0 gave dL ~ log(Ie), a burst of
        // events that the next frames, measured from the primal, do not take back.)
        if (prevI + deltaI <= 0.0)
        {
            deltaIllumination = illumination - prevIllumination;
            deltaI = albedo * deltaIllumination + (albedo - prevAlbedo) * prevIllumination + (emission - prevEmission);
        }
        // The intensities are still clamped at 0 (a negative denoised primal), so dL stays bounded by the bias.
        deltaL = log(gIntensityBias + max(prevI + deltaI, 0.0)) - log(gIntensityBias + max(prevI, 0.0));
        if (!isfinite(deltaL) || !isfinite(deltaI))
        {
            deltaIllumination = 0.0;
            deltaI = 0.0;
            deltaL = 0.0;
        }
    }
    gDeltaIllumination[pixel] = deltaIllumination;
    gDeltaI[pixel] = float4(deltaI, deltaI, deltaI, 0.0);
    gDeltaL[pixel] = deltaL;
    const float3 primal = gUseDemodulation != 0 ? gAlbedo[pixel].rgb * illumination + gEmission[pixel].rgb : float3(illumination);
    gPrimal[pixel] = float4(primal, 1.0);
}
