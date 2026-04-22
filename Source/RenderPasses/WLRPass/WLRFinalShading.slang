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
import WLRCommon;

cbuffer PerImageCB
{
    Texture2D gColor;
    
    // pixel data
    Texture2D gAlbedo;
    Texture2D gLinearZAndNormal;

    // Evaluated coefficients
    Texture2D gBeta1;
    Texture2D gBeta2;
    Texture2D gBeta3;
    Texture2D gAlpha;
};

//-------------------------------------------------------------------------
// Helpers
//-------------------------------------------------------------------------
bool inBounds(int2 p, int2 dim)
{
    return all(p >= int2(0, 0)) && all(p < dim);
}

float3 loadColor(int2 p)
{
    return gColor[p].rgb;
}

float3 loadAlbedo(int2 p)
{
    return gAlbedo[p].rgb;
}

float loadLinearZ(int2 p)
{
    return gLinearZAndNormal[p].x;
}

float3 loadNormal(int2 p)
{
    return oct_to_ndir_snorm(gLinearZAndNormal[p].zw);
}

float safeExpWeight(float x)
{
    // Prevent underflow / denorm weirdness.
    return exp(-min(x, 80.0));
}

float computeFeatureWeight(
    int2 p,
    int2 q,
    float3 aP,
    float3 aQ,
    float  zP,
    float  zQ,
    float3 nP,
    float3 nQ)
{
    const float2 d  = float2(q - p);
    const float  ds = dot(d, d);

    const float spatialTerm = ds / max(gSigmaSpatial * gSigmaSpatial, 1e-8);

    const float3 da = aQ - aP;
    const float  albedoTerm = dot(da, da) / max(gSigmaAlbedo * gSigmaAlbedo, 1e-8);

    // Relative depth difference is usually more stable than absolute difference.
    const float zScale = max(abs(zP), 1e-3);
    const float dz = (zQ - zP) / zScale;
    const float depthTerm = (dz * dz) / max(gSigmaDepth * gSigmaDepth, 1e-8);

    const float nd = saturate(dot(nP, nQ));
    const float normalDiff = 1.0 - nd;
    const float normalTerm = (normalDiff * normalDiff) / max(gSigmaNormal * gSigmaNormal, 1e-8);

    return safeExpWeight(spatialTerm + albedoTerm + depthTerm + normalTerm);
}



// Weighted least-squares with basis [1, x, y].
// We solve for each color channel jointly by accumulating vector RHS.
// Output is beta0 = intercept at center.
float3 weightedLocalLinearRegression(int2 p, int2 screenSize)
{
    const float3 cP = loadColor(p);
    const float3 aP = loadAlbedo(p);
    const float  zP = loadLinearZ(p);
    const float3 nP = loadNormal(p);

    // Normal equations:
    // M = sum_i w_i * phi_i * phi_i^T
    // b = sum_i w_i * phi_i * y_i
    //
    // where phi_i = [1, dx, dy].
    float3x3 M = 0.0;
    float3 bx = 0.0;
    float3 by = 0.0;
    float3 b0 = 0.0;

    float weightSum = 0.0;
    
    [loop]
    for (int oy = -gKernelRadius; oy <= gKernelRadius; ++oy)
    {
        [loop]
        for (int ox = -gKernelRadius; ox <= gKernelRadius; ++ox)
        {
            const int2 q = p + int2(ox, oy);
            if (!inBounds(q, screenSize)) continue;

            const float3 aQ = loadAlbedo(q);
            const float  zQ = loadLinearZ(q);
            const float3 nQ = loadNormal(q);
            const float3 cQ = loadColor(q);

            float w = computeFeatureWeight(p, q, aP, aQ, zP, zQ, nP, nQ);
            if (w < gMinWeight) continue;

            // Normalize coordinates by kernel radius for better conditioning.
            const float r = max(float(gKernelRadius), 1.0);
            const float x = float(ox) / r;
            const float y = float(oy) / r;

            // Accumulate M = sum w * [1 x y]^T [1 x y]
            M[0][0] += w;
            M[0][1] += w * x;
            M[0][2] += w * y;

            M[1][0] += w * x;
            M[1][1] += w * x * x;
            M[1][2] += w * x * y;

            M[2][0] += w * y;
            M[2][1] += w * x * y;
            M[2][2] += w * y * y;

            // Accumulate b = sum w * phi * c
            b0 += w * cQ;
            bx += w * x * cQ;
            by += w * y * cQ;

            weightSum += w;
        }
    }

    // Fallback if neighborhood is degenerate.
    if (weightSum <= 0.0)
        return cP;

    // Tikhonov regularization for stability.
    M[0][0] += gRegressionLambda;
    M[1][1] += gRegressionLambda;
    M[2][2] += gRegressionLambda;

    const float3x3 Minv = inverse(M);

    // Solve for each channel:
    // beta = Minv * [b0, bx, by]
    //
    // Since output at center is phi(0,0) = [1,0,0], we only need beta0.
    const float3 beta0 =
        Minv[0][0] * b0 +
        Minv[0][1] * bx +
        Minv[0][2] * by;

    return max(beta0, 0.0);
}


//-------------------------------------------------------------------------
// Main
//-------------------------------------------------------------------------
float4 main(FullScreenPassVsOut vsOut) : SV_TARGET0
{
    const int2 ipos = int2(vsOut.posH.xy);
    const int2 screenSize = getTextureDims(gAlbedo, 0);

    if (!inBounds(ipos, screenSize))
        return float4(0, 0, 0, 0);

    const float3 denoised = weightedLocalLinearRegression(ipos, screenSize);
    return float4(denoised, 1.0);
}