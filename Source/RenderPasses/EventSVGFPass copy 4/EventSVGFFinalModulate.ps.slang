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

    Texture2D gAccumulatedBrightness;
    float gEventThreshold;

    uint gUseDemodulation;
    uint gUseMotionVectorAlignDifference;
    uint gOutputMotionVectorAlignDifference;
    uint gUseLogScale;
    uint gDenoiseLogScale;
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


struct PS_OUT
{
    float4 OutIllumination : SV_TARGET0;
    float4 OutBrightness : SV_TARGET1;
    float4 OutEvent : SV_TARGET2;
};


PS_OUT main(FullScreenPassVsOut vsOut)
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
    float C_curr = luminance(gColor[ipos].rgb);
    float C_prev_reproj = luminance(gPrevColor2[iposPrev].rgb);
    float C_prev = luminance(gPrevColor2[ipos].rgb);
    
    float epsilon = 1e-10;
    float log_offset = 1;
    float denom = log_offset + A_prev * i_prev + E_prev;

    // (1) use demodulation
    if(gUseDemodulation){
        // (1-1) linear
        // I_t  - I_(t-1) = A_t (i_t - i_(t-1)) + (A_t - A_(t-1)) - i (t-1)  
        // colorA = A_curr * i_diff + (A_curr - A_prev) * i_prev;

        // (1-2) log
        // log(I_t) - log(I_(t-1)) = log A_t - log A_(t-1) + log (1 + (i_t - i_(t-1)) / i_(t-1)) 
        // colorA = safelog(A_curr) - safelog(A_prev) + safelog(1 + i_diff / (i_prev + epsilon));

        // (1-3) linear log
        float nom = A_curr * i_diff + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
        colorA = i_diff;//log(1 + nom / denom);

        nom = A_curr * (i_curr - i_prev) + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
        colorB = i_curr - i_prev;//log(1 + nom / denom);

        if(gUseMotionVectorAlignDifference){
            if(gOutputMotionVectorAlignDifference){
                colorA = i_diff;
            } else {
                float dx = ddx(i_prev) * motion.x * imageDim.x;
                float dy = ddy(i_prev) * motion.y * imageDim.y;

                colorA = isReprojIposValid ? i_diff + i_prev_reproj - i_prev : i_curr - i_prev;
            }
        } else {
            if(gOutputMotionVectorAlignDifference){
                colorA = i_diff  + i_prev - i_prev_reproj;
            } else {
                colorA = isIposValid ? i_diff : i_curr - i_prev;
            }
        }
        

        
        // float4 reprojprevIllum;
        // loadPrevData(ipos, reprojprevIllum);
        nom = A_curr * (i_diff + i_prev_reproj - i_prev) + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
        colorD = nom;//i_diff;//(i_diff + i_prev_reproj - i_prev); //log(1 + nom / denom);

        // float colorA1 = luminance(gAlbedo[ipos].rgb) * gIllumination[ipos].g + luminance(gEmission[ipos].rgb);
        // float colorA2 = (luminance(gPrevAlbedo[ipos].rgb) - luminance(gAlbedo[ipos].rgb)) * gPrevIllumination[ipos].r + luminance(gPrevEmission[ipos].rgb);
        // colorA = colorA1 - colorA2;

        // // (B) from denoised primal
        // float colorB1 = luminance(gAlbedo[ipos].rgb) * gIllumination[ipos].r + luminance(gEmission[ipos].rgb);
        // float colorB2 = luminance(gPrevAlbedo[ipos].rgb) * gPrevIllumination[ipos].r + luminance(gPrevEmission[ipos].rgb);
        // colorB = safelog(colorB1) - safelog(colorB2);
        
        // float colorA = luminance(gAlbedo[ipos].rgb * gIllumination[ipos].g + gEmission[ipos].rgb)
        //     + luminance((gAlbedo[ipos].rgb -) * gPrevIllumination[ipos].r + gPrevEmission[ipos].rgb);
        // // (B) from denoised primal
        // float colorB = luminance(gAlbedo[ipos].rgb * gIllumination[ipos].r + gEmission[ipos].rgb) 
        // - luminance(gPrevAlbedo[ipos].rgb * gPrevIllumination[ipos].r + gPrevEmission[ipos].rgb);
    } 
    else {
        // (A) from denoised difference
        colorA = gIllumination[ipos].g;
        colorB = gIllumination[ipos].r - gPrevIllumination[ipos].r;
    }

    // float x = gIllumination[ipos].g / max(gPrevIllumination[ipos].r, 1e-6);
    // float colorC = safelog(luminance(gAlbedo[ipos].rgb)) - safelog(luminance(gPrevAlbedo[ipos].rgb)) + safelog(1 + x);
    // gIllumination[ipos].g;
    // colorC = safelog(luminance(gAlbedo[ipos].rgb)) - safelog(luminance(gPrevAlbedo[ipos].rgb)) + safelog();
    // float colorA2 = 
    // return float4(colorA / max(gPrevIllumination[ipos].r, 0.001), colorB, colorC, gIllumination[ipos].r);
    colorD = luminance(gColor[ipos].rgb) - luminance(gPrevColor2[ipos].rgb);
    if(gOutputMotionVectorAlignDifference){
        colorB = isReprojIposValid ? i_curr - i_prev_reproj : 0.0;
    } else {
        colorB = i_curr - i_prev;
    }
    colorA = A_curr * colorA + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
    colorA = log(1 + colorA / denom);

    colorB = A_curr * colorB + (A_curr - A_prev) * i_prev + (E_curr - E_prev);
    colorB = log(1 + colorB / denom);
    
    
    float accumulatedBrightnessA = gAccumulatedBrightness[ipos].r + colorA;
    float accumulatedBrightnessB = gAccumulatedBrightness[ipos].g + colorB;

    float eventA = 0;
    if(accumulatedBrightnessA > gEventThreshold){
        accumulatedBrightnessA = fmod(accumulatedBrightnessA, gEventThreshold);
        eventA = 1;
    }
    if(accumulatedBrightnessA < -gEventThreshold){
        accumulatedBrightnessA = fmod(accumulatedBrightnessA, gEventThreshold);
        eventA = -1;
    }

    float eventB = 0;
    if(accumulatedBrightnessB > gEventThreshold){
        accumulatedBrightnessB = fmod(accumulatedBrightnessB, gEventThreshold);
        eventB = 1;
    }
    if(accumulatedBrightnessB < -gEventThreshold){
        accumulatedBrightnessB = fmod(accumulatedBrightnessB, gEventThreshold);
        eventB = -1;
    }

    psOut.OutIllumination = float4(colorA, colorB, gIllumination[ipos].r, colorD);
    psOut.OutBrightness.r = accumulatedBrightnessA;
    psOut.OutEvent.r = eventA;
    psOut.OutBrightness.g = accumulatedBrightnessB;
    psOut.OutEvent.b = eventB;
    return psOut;


    // if(gOutputMotionVectorAlignDifference){
    //     colorA = A_curr * colorA + (A_curr - A_prev_reproj) * i_prev + (E_curr - E_prev_reproj);
    //     colorB = A_curr * colorB + (A_curr - A_prev_reproj) * i_prev + (E_curr - E_prev_reproj);
    // } else {
    // }
    //

    // if(gUseLogScale && gDenoiseLogScale){

    // }

    // return gColor[ipos] - gPrevColor2[ipos];

    // if(gUseDemodulation){
    //     float color = luminance(gAlbedo[ipos].rgb * gIllumination[ipos].g) 
    //         + luminance((gAlbedo[ipos].rgb - gPrevAlbedo[ipos].rgb) * gPrevIllumination[ipos].r);
    //     float emissiondiff = luminance(gEmission[ipos].rgb - gPrevEmission[ipos].rgb);

    //     return float4(color + emissiondiff);
    // }
    // float color = gIllumination[ipos].g;

    // float color = luminance(gAlbedo[ipos].rgb * gIllumination[ipos].r + gEmission[ipos].rgb) 
    //     - luminance(gPrevAlbedo[ipos].rgb * gPrevIllumination[ipos].r + gPrevEmission[ipos].rgb);
    // float emissiondiff = luminance( - gPrevEmission[ipos].rgb);

    
    // return float4(color);
    
    // return gAlbedo[ipos] * gIllumination[ipos] + gEmission[ipos];
}
