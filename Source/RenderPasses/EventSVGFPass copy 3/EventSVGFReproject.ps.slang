/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;
import EventSVGFCommon;

// Workaround for isnan() not working in slang.
bool isNaN(float f)
{
    uint u = asuint(f) & ~0x80000000u; // clear out the sign bit
    return (u > 0x7F800000);           // greater than Inf is NaN
}

cbuffer PerImageCB
{
    Texture2D gMotion;
    Texture2D gPositionNormalFwidth;
    Texture2D gColor;
    Texture2D gColor2;
    Texture2D gPrevColor2;
    Texture2D gAlbedo;
    Texture2D gPrevAlbedo;
    Texture2D gEmission;
    Texture2D gPrevEmission;
    Texture2D gPrevIllum;
    Texture2D gPrevPrevIllum;
    Texture2D gPrevReprojIllum;
    Texture2D gPrevMoments;
    Texture2D gLinearZAndNormal;
    Texture2D gPrevLinearZAndNormal;
    Texture2D gPrevPrevLinearZAndNormal;
    Texture2D gPrevHistoryLength;

    float gAlpha;
    float gMomentsAlpha;
    uint gFrameCount;
    uint gUseDemodulation;
    uint gUseLogScale;
    uint gDenoiseLogScale;
    uint gUseMotionVectorAlignDifference;
};

float demodulate(float3 i, float3 e, float3 albedo)
{
    return (luminance(i) - luminance(e)) / max(luminance(albedo), 0.001);
}

// float demodulate(float c, float albedo)
// {
//     return c / max(albedo, 0.001);
// }

bool isReprjValid(int2 coord, float Z, float Zprev, float fwidthZ, float3 normal, float3 normalPrev, float fwidthNormal)
{
    const int2 imageDim = getTextureDims(gColor, 0);

    // check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1, 1)) || any(coord > imageDim - int2(1, 1)))
        return false;

    if(abs(Zprev - Z) > 0.05f * abs(Z))
        return false;
    if(dot(normal, normalPrev) < 0.9)
        return false;
    // // check if deviation of depths is acceptable
    // if (abs(Zprev - Z) / (fwidthZ + 1e-2f) > 10.f)
    //     return false;

    // // check normals for compatibility
    // if (distance(normal, normalPrev) / (fwidthNormal + 1e-2) > 16.0)
    //     return false;

    return true;
}

bool isReprjValid2(int2 coord, float Z, float Zprev, float fwidthZ, float3 normal, float3 normalPrev, float fwidthNormal)
{
    const int2 imageDim = getTextureDims(gColor, 0);

    // check whether reprojected pixel is inside of the screen
    if (any(coord < int2(1, 1)) || any(coord > imageDim - int2(1, 1)))
        return false;

    if(abs(Zprev - Z) > 0.01f * abs(Z))
        return false;
    if(dot(normal, normalPrev) < 0.99999)
        return false;
    return true;
}

bool loadPrevData(float2 posH, out float prevIllum, out float2 prevMoments, out float historyLength, 
    out float prevprevIllum, out float prevDiffIllum, out float2 prevdiffMoments, out bool prevDiffValid, out float historyLengthDiff)
{
    const int2 ipos = posH;
    const float2 imageDim = float2(getTextureDims(gColor, 0));

    const float2 motion = gMotion[ipos].xy;
    const float normalFwidth = gPositionNormalFwidth[ipos].y;

    // +0.5 to account for texel center offset
    const int2 iposPrev = int2(float2(ipos) + motion.xy * imageDim + float2(0.5, 0.5));

    float2 depth = gLinearZAndNormal[ipos].xy;
    float3 normal = oct_to_ndir_snorm(gLinearZAndNormal[ipos].zw);

    prevIllum = 0.0;
    prevDiffIllum = 0.0;
    prevprevIllum = 0.0;
    prevMoments = float2(0, 0);
    prevdiffMoments = float2(0, 0);

    bool v[4];
    bool vPrev[4];
    const float2 posPrev = floor(posH.xy) + motion.xy * imageDim;
    const int2 offset[4] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1) };

    // check for all 4 taps of the bilinear filter for validity
    bool valid = false;
    bool validPrev = false;
    for (int sampleIdx = 0; sampleIdx < 4; sampleIdx++)
    {
        int2 loc = int2(posPrev) + offset[sampleIdx];
        float2 depthPrev = gPrevLinearZAndNormal[loc].xy;
        float3 normalPrev = oct_to_ndir_snorm(gPrevLinearZAndNormal[loc].zw);
        float2 depthPrevPrev = gPrevPrevLinearZAndNormal[loc].xy;
        float3 normalPrevPrev = oct_to_ndir_snorm(gPrevPrevLinearZAndNormal[loc].zw);

        v[sampleIdx] = isReprjValid(iposPrev, depth.x, depthPrev.x, depth.y, normal, normalPrev, normalFwidth);
        vPrev[sampleIdx] = isReprjValid(iposPrev, depthPrev.x, depthPrevPrev.x, depthPrev.y, normalPrev, normalPrevPrev, normalFwidth) && 
            isReprjValid(iposPrev, depth.x, depthPrevPrev.x, depth.y, normal, normalPrevPrev, normalFwidth) && (gPrevHistoryLength[loc].y >= 1);

        valid = valid || v[sampleIdx];
        validPrev = validPrev || (vPrev[sampleIdx] && v[sampleIdx]);
    }

    if (valid)
    {
        float sumw = 0;
        float sumwDiff = 0;
        float x = frac(posPrev.x);
        float y = frac(posPrev.y);

        // bilinear weights
        const float w[4] = { (1 - x) * (1 - y), x * (1 - y), (1 - x) * y, x * y };

        // perform the actual bilinear interpolation
        for (int sampleIdx = 0; sampleIdx < 4; sampleIdx++)
        {
            const int2 loc = int2(posPrev) + offset[sampleIdx];
            if (v[sampleIdx])
            {
                prevIllum += w[sampleIdx] * gPrevIllum[loc].r;
                prevMoments += w[sampleIdx] * gPrevMoments[loc].xy;
                sumw += w[sampleIdx];
            }
            if(gUseMotionVectorAlignDifference){
                if(v[sampleIdx]){
                    prevDiffIllum += w[sampleIdx] * gPrevIllum[loc].g;
                    prevprevIllum += w[sampleIdx] * gPrevPrevIllum[loc].r;
                    prevdiffMoments += w[sampleIdx] * gPrevMoments[loc].zw;
                    sumwDiff += w[sampleIdx];
                }
            } else {
                if(v[sampleIdx] && vPrev[sampleIdx]){
                    prevDiffIllum += w[sampleIdx] * gPrevIllum[loc].g;
                    prevprevIllum += w[sampleIdx] * gPrevPrevIllum[loc].r;
                    prevdiffMoments += w[sampleIdx] * gPrevMoments[loc].zw;
                    sumwDiff += w[sampleIdx];
                }
            }
            
        }

        // redistribute weights in case not all taps were used
        valid = (sumw >= 0.01);
        prevIllum = valid ? prevIllum / sumw : 0.0;
        prevMoments = valid ? prevMoments / sumw : float2(0, 0);

        validPrev = (sumwDiff > 0.01);
        prevDiffIllum = validPrev ? prevDiffIllum / sumwDiff : 0.0;
        prevprevIllum = validPrev ? prevprevIllum / sumwDiff : 0.0;
        prevdiffMoments = validPrev ? prevdiffMoments / sumwDiff : float2(0, 0);
    }

    if (valid)
    {
        // crude, fixme
        historyLength = gPrevHistoryLength[iposPrev].x;
    }
    else
    {
        prevIllum = 0.0;
        prevMoments = float2(0, 0);
        historyLength = 0;
    }
    if(!gUseMotionVectorAlignDifference){
        prevDiffValid = valid && validPrev;
        if(prevDiffValid){
            historyLengthDiff = gPrevHistoryLength[iposPrev].y;
        } else {
            historyLengthDiff = 0;
            prevDiffIllum = 0;
            prevprevIllum = 0;
            prevdiffMoments = float2(0,0);
        }
    }
    return valid;
}


// not used currently
float computeVarianceScale(float numSamples, float loopLength, float alpha)
{
    const float aa = (1.0 - alpha) * (1.0 - alpha);
    return (1.0 - pow(aa, min(loopLength, numSamples))) / (1.0 - aa);
}

struct PS_OUT
{
    float4 OutIllumination : SV_TARGET0;
    float2 OutMoments : SV_TARGET1;
    float2 OutHistoryLength : SV_TARGET2;
    float4 OutIllumination2 : SV_TARGET3;
};

PS_OUT main(FullScreenPassVsOut vsOut)
{
    const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;

    float historyLength;
    float prevIllumination;
    float prevDiffIllumination;
    float prevprevIllumination;

    float2 prevMoments;
    float2 prevdiffMoments;

    bool prevDiffValid;
    float historyLengthDiff;

    bool success = loadPrevData(posH.xy, prevIllumination, prevMoments, historyLength, 
        prevprevIllumination, prevDiffIllumination, prevdiffMoments, prevDiffValid, historyLengthDiff);
    historyLength = min(32.0f, success ? historyLength + 1.0f : 1.0f);
    historyLengthDiff = min(32.0f, prevDiffValid ? historyLengthDiff + 1.0f : 1.0f);
    
    float2 depthCurr = gLinearZAndNormal[ipos].xy;
    float3 normalCurr = oct_to_ndir_snorm(gLinearZAndNormal[ipos].zw);
    float2 depthPrev = gPrevLinearZAndNormal[ipos].xy;
    float3 normalPrev = oct_to_ndir_snorm(gPrevLinearZAndNormal[ipos].zw);
    const float normalFwidth = gPositionNormalFwidth[ipos].y;
    bool isIposValid = isReprjValid(ipos, depthCurr.x, depthPrev.x, depthCurr.y, normalCurr, normalPrev, normalFwidth);

    historyLengthDiff = gPrevHistoryLength[ipos].y;
    historyLengthDiff = (isIposValid && (gFrameCount > 0)) ? historyLengthDiff + 1 : 0.0;

    // (abs(depthCurr.x - depthPrev.x) < 0.1 * depthCurr.x) && dot(normalCurr, normalPrev) > 0.9;
    // isReprjValid(ipos, depth.x, depthPrev.x, depth.y, normal, normalPrev, normalFwidth);

    float prev_illum2, curr_illum1, curr_illum2;

    int2 imageDim = getTextureDims(gColor, 0);
    float2 motion = gMotion[ipos].xy;
    int2 iposPrev = int2(float2(ipos) + motion.xy * imageDim + float2(0.5, 0.5));
    int2 iposPrevProj = int2(float2(ipos) + motion.xy * imageDim + float2(0.5, 0.5));
    if(!gUseMotionVectorAlignDifference){
        iposPrev = ipos;
    }
    float2 depthPrevReproj = gPrevLinearZAndNormal[iposPrev].xy;
    float3 normalPrevReproj = oct_to_ndir_snorm(gPrevLinearZAndNormal[iposPrev].zw);
    bool isReprojIposValid = isReprjValid(ipos, depthCurr.x, depthPrevReproj.x, depthCurr.y, normalCurr, normalPrevReproj, normalFwidth);


    // demodulate
    if(gUseDemodulation){
        prev_illum2 = demodulate(gPrevColor2[iposPrev].rgb, gPrevEmission[iposPrev].rgb, gPrevAlbedo[iposPrev].rgb);
        curr_illum1 = demodulate(gColor[ipos].rgb, gEmission[ipos].rgb, gAlbedo[ipos].rgb);
        curr_illum2 = demodulate(gColor2[ipos].rgb, gEmission[ipos].rgb, gAlbedo[ipos].rgb);
    } else {
        prev_illum2 = luminance(gPrevColor2[iposPrev].rgb);
        curr_illum1 = luminance(gColor[ipos].rgb);
        curr_illum2 = luminance(gColor2[ipos].rgb);
    }
    
    // Average and Difference
    float avg_luminance = (curr_illum1 + curr_illum2) * 0.5;
    float diff_luminance = (curr_illum1 - prev_illum2);
    
    // this adjusts the alpha for the case where insufficient history is available.
    // It boosts the temporal accumulation to give the samples equal weights in
    // the beginning.
    const float alpha = success ? max(gAlpha, 1.0 / historyLength) : 1.0;
    const float alphaMoments = success ? max(gMomentsAlpha, 1.0 / historyLength) : 1.0;

    // compute first two moments of luminance
    float2 moments;
    moments.r = avg_luminance;
    moments.g = moments.r * moments.r;
    // temporal integration of the moments
    moments = lerp(prevMoments, moments, alphaMoments);
    float variance = max(0.f, moments.g - moments.r * moments.r);

    
    float2 diffmoments;
    diffmoments.r = abs(diff_luminance);
    diffmoments.g = diffmoments.r * diffmoments.r;
    // temporal integration of the moments
    diffmoments = lerp(prevdiffMoments, diffmoments, alphaMoments);
    float diffvariance = max(0.f, diffmoments.g - diffmoments.r * diffmoments.r);

    // variance *= computeVarianceScale(16, 16, alpha);
    // float prev_diff = prevIllumination.r - gPrevReprojIllum[ipos].r;
    

    // if(gUseMotionVectorAlignDifference){
    // } else {
    //     prev_diff = prevIllumination.g + prevprevIllumination.r - gPrevReprojIllum[ipos].r;
    // }
    
    // = prevIllumination.g;// + prevprevIllumination.r - gPrevReprojIllum[ipos].r;
    // cprev_diff = prevIllumination.r - gPrevReprojIllum[ipos].r;
    PS_OUT psOut;
    // temporal integration of illumination
    psOut.OutIllumination.r = lerp(prevIllumination, avg_luminance, alpha);
    // psOut.OutIllumination.g = lerp(prev_diff, diff_luminance, (historyLength >= 2)
    //      && (gPrevHistoryLength[ipos].x >= 2) && isIposValid ? alpha : 1.0);
    
    // Temporal accumulation
    if(gUseMotionVectorAlignDifference){
        float prev_diff = prevDiffIllumination;
        psOut.OutIllumination.g = lerp(prev_diff, diff_luminance, alpha);
        if(!isReprojIposValid){
            psOut.OutIllumination.g = 0.0;
        }
    } else {
        float prev_diff = prevDiffIllumination + prevprevIllumination - gPrevReprojIllum[ipos].r;
        // prevDiffValid ? 0.0 : 1.0;//
        psOut.OutIllumination.g = lerp(prev_diff, diff_luminance, ((historyLength >= 3) && isIposValid && prevDiffValid && gPrevReprojIllum[ipos].r > 0.0) ? alpha : 1.0);
        // if(!isIposValid || !prevDiffValid){
        //     psOut.OutIllumination.g = diff_luminance;
        // }
    }
    
    // lerp(prev_diff, diff_luminance, alpha);
    // psOut.OutIllumination.g = lerp(prev_diff, diff_luminance, (historyLength >= 2) ? alpha : 1.0);
    
    // psOut.OutIllumination.g = diff_luminance;
    // variance is propagated through the alpha channel
    psOut.OutIllumination2 = float4(prevIllumination, prevDiffIllumination, 0.0, 1.0);
    psOut.OutIllumination.a = variance;
    psOut.OutMoments = moments;
    psOut.OutHistoryLength = float2(historyLength, historyLengthDiff);

    return psOut;
}
