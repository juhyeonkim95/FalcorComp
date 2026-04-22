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
import SVGFEventCommon;

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
    Texture2D gAlbedo;
    Texture2D gEmission;
    Texture2D gPrevColor;
    Texture2D gPrevAlbedo;
    Texture2D gPrevEmission;
    Texture2D gPrevIllum;
    Texture2D gPrevMoments;
    Texture2D gLinearZAndNormal;
    Texture2D gPrevLinearZAndNormal;
    Texture2D gPrevHistoryLength;

    float gAlpha;
    float gMomentsAlpha;
};

// float3 demodulate(float3 c, float3 albedo)
// {
//     return c / max(albedo, float3(0.001, 0.001, 0.001));
// }

float demodulate(float3 c, float3 e, float3 albedo)
{
    return (luminance(c) - luminance(e)) / max(luminance(albedo), 0.001);
}

struct PS_OUT
{
    float4 OutIllumination : SV_TARGET0;
    float2 OutMoments : SV_TARGET1;
    float OutHistoryLength : SV_TARGET2;
};

PS_OUT main(FullScreenPassVsOut vsOut)
{
    const float4 posH = vsOut.posH;
    const int2 ipos = posH.xy;

    float illumination = demodulate(gColor[ipos].rgb, gEmission[ipos].rgb, gAlbedo[ipos].rgb);
    float previllumination = demodulate(gPrevColor[ipos].rgb, gPrevEmission[ipos].rgb, gPrevAlbedo[ipos].rgb);
    
    PS_OUT psOut;
    // temporal integration of illumination
    psOut.OutIllumination.r = illumination;
    psOut.OutIllumination.g = illumination - previllumination;
    psOut.OutIllumination.b = illumination - previllumination;
    // (psOut.OutIllumination.g);
    psOut.OutIllumination.a = 0.0;
    // psOut.OutMoments = moments;
    psOut.OutHistoryLength = 0.0;

    return psOut;
}
