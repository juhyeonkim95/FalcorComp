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

cbuffer PerImageCB
{
    Texture2D gAlbedo;
    Texture2D gEmission;
    Texture2D gPrevAlbedo;
    Texture2D gPrevEmission;
    Texture2D gIllumination;
    Texture2D gPrevIllumination;
    Texture2D gColor;
    Texture2D gPrevColor2;

    Texture2D gMotion;
    Texture2D gPositionNormalFwidth;
    Texture2D gLinearZAndNormal;
    Texture2D gPrevLinearZAndNormal;

    uint gUseDemodulation;
    uint gUseMotionVectorAlignDifference;
    uint gOutputMotionVectorAlignDifference;
    uint gUseLogScale;
    uint gDenoiseLogScale;
    float gIntensityBias;
    bool gUseDenoisedDifference;
    uint gFrameCount;
};


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
    // // if(distance(normal, normalPrev) > 0.0)
    // //     return false;

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


bool loadPrevData(float2 posH, out float prevIllum)
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

        v[sampleIdx] = isReprjValid(loc, depth.x, depthPrev.x, depth.y, normal, normalPrev, normalFwidth);
        valid = valid || v[sampleIdx];
    }

    if (valid)
    {
        float sumw = 0;
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
                prevIllum += w[sampleIdx] * gPrevIllumination[loc].r;
                sumw += w[sampleIdx];
            }
        }

        // redistribute weights in case not all taps were used
        valid = (sumw >= 0.01);
        prevIllum = valid ? prevIllum / sumw : 0.0;
    }

    if (valid)
    {
    }
    else
    {
        prevIllum = 0.0;
    }

    return valid;
}



float4 main(FullScreenPassVsOut vsOut) : SV_TARGET0
{
    const int2 ipos = int2(vsOut.posH.xy);
    float colorA, colorB, colorC, colorD;

    const float2 motion = gMotion[ipos].xy;
    const int2 imageDim = getTextureDims(gColor, 0);
    const int2 iposPrev = int2(float2(ipos) + motion.xy * imageDim + float2(0.5, 0.5));

    float2 depthCurr = gLinearZAndNormal[ipos].xy;
    float3 normalCurr = oct_to_ndir_snorm(gLinearZAndNormal[ipos].zw);
    const float normalFwidth = gPositionNormalFwidth[ipos].y;

    float2 depthPrev = gPrevLinearZAndNormal[ipos].xy;
    float3 normalPrev = oct_to_ndir_snorm(gPrevLinearZAndNormal[ipos].zw);
    bool isIposValid = isReprjValid(ipos, depthCurr.x, depthPrev.x, depthCurr.y, normalCurr, normalPrev, normalFwidth);
    
    float2 depthPrevReproj = gPrevLinearZAndNormal[iposPrev].xy;
    float3 normalPrevReproj = oct_to_ndir_snorm(gPrevLinearZAndNormal[iposPrev].zw);
    bool isReprojIposValid = isReprjValid(ipos, depthCurr.x, depthPrevReproj.x, depthCurr.y, normalCurr, normalPrevReproj, normalFwidth);
    
    float A_curr = luminance(gAlbedo[ipos].rgb);
    float A_prev = luminance(gPrevAlbedo[ipos].rgb);
    float A_prev_reproj = luminance(gPrevAlbedo[iposPrev].rgb);
    float E_curr = luminance(gEmission[ipos].rgb);
    float E_prev = luminance(gPrevEmission[ipos].rgb);
    float E_prev_reproj = luminance(gPrevEmission[iposPrev].rgb);
    float i_diff = gIllumination[ipos].g;
    float i_curr = gIllumination[ipos].r;
    float i_prev = gPrevIllumination[ipos].r;
    float i_prev_reproj = gPrevIllumination[iposPrev].r;
    // float i_prev_reproj_bilinear;
    // loadPrevData(ipos, i_prev_reproj_bilinear);
    float C_curr = luminance(gColor[ipos].rgb);
    float C_prev_reproj = luminance(gPrevColor2[iposPrev].rgb);
    float C_prev = luminance(gPrevColor2[ipos].rgb);
    
    isIposValid &= ((length(E_curr) == 0) || (length(E_prev) == 0));

    if(gFrameCount == 0){
        float deltai = i_curr;
        float deltaI = A_curr * i_curr + E_curr;
        float deltaL = log(gIntensityBias + deltaI);
        return float4(deltai, deltaI, deltaL, 0.0);
    }

    float deltai = (isIposValid && gUseDenoisedDifference) ? i_diff : i_curr - i_prev;
    float deltaI = A_curr * deltai + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
    float prevI = A_prev * i_prev + E_prev;
    float value = 1 + deltaI / (prevI + gIntensityBias);
    float deltaL = log(max(value, 1e-10));
    return float4(deltai, deltaI, deltaL, 0.0);
    
    // if(!gUseMotionVectorAlignDifference){
        
    // }

    // float deltai = (isReprojIposValid) ? i_diff + i_prev_reproj - i_prev  : i_curr - i_prev;
    // float deltaI = A_curr * deltai + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
    // float prevI = A_prev * i_prev + E_prev;
    // float deltaL = log(1 + deltaI / (prevI + gIntensityBias));

    // return float4(deltai, deltaI, deltaL, 0.0);
}
