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
import SVGFEventCommon;
import Utils.Color.ColorHelpers;

cbuffer PerImageCB
{
    Texture2D gAlbedo;
    Texture2D gEmission;
    Texture2D gPrevAlbedo;
    Texture2D gPrevEmission;
    Texture2D gIllumination;
    Texture2D gPrevIllumination;
    Texture2D gColor;
    Texture2D gPrevColor;
};

float demodulate(float3 c, float3 e, float3 albedo)
{
    return (luminance(c) - luminance(e)) / max(luminance(albedo), 0.001);
}

float4 main(FullScreenPassVsOut vsOut) : SV_TARGET0
{
    const int2 ipos = int2(vsOut.posH.xy);
    float a = gIllumination[ipos].b;
    
    float illumination = demodulate(gColor[ipos].rgb, gEmission[ipos].rgb, gAlbedo[ipos].rgb);
    float previllumination = demodulate(gPrevColor[ipos].rgb, gPrevEmission[ipos].rgb, gPrevAlbedo[ipos].rgb);
    float r = illumination - previllumination;

    return float4(a, r, 0.0, 1.0) ;

    return gAlbedo[ipos] * gIllumination[ipos] + gEmission[ipos];
}
