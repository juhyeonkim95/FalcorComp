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

//------------------------------------------------------------------------------
// Constants
//------------------------------------------------------------------------------
cbuffer PerImageCB
{
    Texture2D gColor;
    
    // pixel data
    Texture2D gAlbedo;
    Texture2D gLinearZAndNormal;

    // previous data
    Texture2D gPrevColor;
    Texture2D gPrevAlbedo;
    Texture2D gPrevLinearZAndNormal;

    // previous coefficients
    Texture2D gPrevBeta1;
    Texture2D gPrevBeta2;
    Texture2D gPrevBeta3;
    Texture2D gPrevAlphaResidual;

    float eventThreshold;   // C in paper
    int   kernelRadius;     // e.g. 2 => 5x5
    float minWeight;        // e.g. 1e-6
    float ridgeLambda;      // e.g. 1e-4
    
    float gSigmaSpatial;      // e.g. 1.5
    float gSigmaAlbedo;       // e.g. 0.20
    float gSigmaDepth;        // e.g. 0.02  (relative depth scale)
    float gSigmaNormal;       // e.g. 0.10  (for 1 - dot(n0,n1))

};


//------------------------------------------------------------------------------
// Output
//------------------------------------------------------------------------------
struct PS_OUT
{
    float4 beta1    : SV_TARGET0;
    float4 beta2    : SV_TARGET1;
    float4 beta3    : SV_TARGET2;
    float4 alphaResidual    : SV_TARGET3;
    float4 color    : SV_TARGET4;
    float4 albedo    : SV_TARGET5;
    float4 linearZAndNormal    : SV_TARGET6;
};

//------------------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------------------
static const int kFeatureDim = 9;
static const int kBasisDim   = 10; // [1, 9 features]

bool inBounds(int2 p, int2 dim)
{
    return all(p >= int2(0, 0)) && all(p < dim);
}

float loadLogBrightness(Texture2D<float4> tex, int2 p)
{
    return luminance(tex[p].rgb);
    // const float y = max(luminance(tex[p].rgb), 1e-6);
    // return log(y);
}

float3 loadAlbedo(Texture2D<float4> tex, int2 p)
{
    return tex[p].rgb;
}

float loadLinearZ(Texture2D<float4> tex, int2 p)
{
    return tex[p].x;
}

float3 loadNormal(Texture2D<float4> tex, int2 p)
{
    return oct_to_ndir_snorm(tex[p].zw);
}

void unpackBeta(float3 b1, float3 b2, float3 b3, out float beta[kFeatureDim])
{
    beta[0] = b1.x; // dx
    beta[1] = b1.y; // dy
    beta[2] = b1.z; // nx

    beta[3] = b2.x; // ny
    beta[4] = b2.y; // nz
    beta[5] = b2.z; // z

    beta[6] = b3.x; // albedo.r
    beta[7] = b3.y; // albedo.g
    beta[8] = b3.z; // albedo.b
}

void packBeta(const float beta[kFeatureDim], out float4 b1, out float4 b2, out float4 b3)
{
    b1 = float4(beta[0], beta[1], beta[2], 1.0);
    b2 = float4(beta[3], beta[4], beta[5], 1.0);
    b3 = float4(beta[6], beta[7], beta[8], 1.0);
}

void makeBasis(const float feat[kFeatureDim], out float phi[kBasisDim])
{
    phi[0] = 1.0;
    [unroll]
    for (int i = 0; i < kFeatureDim; ++i) phi[i + 1] = feat[i];
}

float dotBeta(const float beta[kFeatureDim], const float feat[kFeatureDim])
{
    float s = 0.0;
    [unroll]
    for (int i = 0; i < kFeatureDim; ++i) s += beta[i] * feat[i];
    return s;
}

// float computeFeatureWeight(const float feat[kFeatureDim])
// {
//     // Epanechnikov kernel
//     float w = 1.0;
//     [unroll]
//     for (int i = 0; i < kFeatureDim; ++i) w *= max(0.75 * (1.0 - feat[i] * feat[i]), 1e-6);
//     return w;
// }

float safeExpWeight(float x)
{
    // Prevent underflow / denorm weirdness.
    return exp(-min(x, 80.0));
}

// Weight with h = 1, b_j = 1 for all j.
float computeFeatureWeight(
    int2 q, int2 p, 
    float3 nQ, float3 nP,
    float  zQ, float  zP,
    float3 aQ, float3 aP
)
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

    // float w1 = max(0.75 * (1.0 - spatialTerm), 1e-4);
    // float w2 = max(0.75 * (1.0 - albedoTerm), 1e-4);
    // float w3 = max(0.75 * (1.0 - depthTerm), 1e-4);
    // float w4 = max(0.75 * (1.0 - normalTerm), 1e-4);
    // return w1 * w2 * w3 * w4;

    return safeExpWeight(spatialTerm + albedoTerm + depthTerm + normalTerm);
}


void makeFeatureDiff(
    int2 q, int2 center,
    float3 nQ, float3 nC,
    float  zQ, float  zC,
    float3 aQ, float3 aC,
    out float feat[kFeatureDim])
{
    feat[0] = float(q.x - center.x) / float(2 * kernelRadius); // dx
    feat[1] = float(q.y - center.y) / float(2 * kernelRadius); // dy

    const float3 dn = nQ - nC;
    feat[2] = dn.x;
    feat[3] = dn.y;
    feat[4] = dn.z;

    feat[5] = zQ - zC;

    const float3 da = aQ - aC;
    feat[6] = da.x;
    feat[7] = da.y;
    feat[8] = da.z;
}

//------------------------------------------------------------------------------
// Small dense solver: Gauss-Jordan for 10x10
//------------------------------------------------------------------------------
bool solveLinearSystem10(inout float A[kBasisDim][kBasisDim], inout float b[kBasisDim])
{
    [unroll]
    for (int col = 0; col < kBasisDim; ++col)
    {
        int pivotRow = col;
        float pivotAbs = abs(A[col][col]);

        [unroll]
        for (int r = col + 1; r < kBasisDim; ++r)
        {
            const float v = abs(A[r][col]);
            if (v > pivotAbs)
            {
                pivotAbs = v;
                pivotRow = r;
            }
        }

        if (pivotAbs < 1e-10)
            return false;

        if (pivotRow != col)
        {
            [unroll]
            for (int c = 0; c < kBasisDim; ++c)
            {
                const float tmp = A[col][c];
                A[col][c] = A[pivotRow][c];
                A[pivotRow][c] = tmp;
            }

            const float tmpb = b[col];
            b[col] = b[pivotRow];
            b[pivotRow] = tmpb;
        }

        const float invPivot = 1.0 / A[col][col];
        [unroll]
        for (int c = 0; c < kBasisDim; ++c) A[col][c] *= invPivot;
        b[col] *= invPivot;

        [unroll]
        for (int r = 0; r < kBasisDim; ++r)
        {
            if (r == col) continue;

            const float f = A[r][col];
            if (abs(f) < 1e-20) continue;

            [unroll]
            for (int c = 0; c < kBasisDim; ++c)
                A[r][c] -= f * A[col][c];

            b[r] -= f * b[col];
        }
    }

    return true;
}

//------------------------------------------------------------------------------
// Compute shifted residual using PREVIOUS neighborhood and PREVIOUS observations,
// but with either previous center or current center in the feature differences.
// Here we only need the shifted version for update testing.
//------------------------------------------------------------------------------
float computeShiftedResidual(
    int2 ipos,
    int2 screenSize,
    float prevAlpha,
    const float prevBeta[kFeatureDim])
{
    const float3 nCurrC = loadNormal(gLinearZAndNormal, ipos);
    const float  zCurrC = loadLinearZ(gLinearZAndNormal, ipos);
    const float3 aCurrC = loadAlbedo(gAlbedo, ipos);

    float sumW = 0.0;
    float sumR = 0.0;

    [loop]
    for (int oy = -kernelRadius; oy <= kernelRadius; ++oy)
    {
        [loop]
        for (int ox = -kernelRadius; ox <= kernelRadius; ++ox)
        {
            const int2 q = ipos + int2(ox, oy);
            if (!inBounds(q, screenSize)) continue;

            const float yPrev = loadLogBrightness(gPrevColor, q);

            const float3 nQPrev = loadNormal(gPrevLinearZAndNormal, q);
            const float  zQPrev = loadLinearZ(gPrevLinearZAndNormal, q);
            const float3 aQPrev = loadAlbedo(gPrevAlbedo, q);

            float feat[kFeatureDim];
            makeFeatureDiff(
                q, ipos,
                nQPrev, nCurrC,
                zQPrev, zCurrC,
                aQPrev, aCurrC,
                feat);

            // Weight stays anchored to previous support.
            const float w = computeFeatureWeight(q, ipos, nQPrev, nCurrC, zQPrev, zCurrC, aQPrev, aCurrC);
            if (w < minWeight) continue;

            const float pred = prevAlpha + dotBeta(prevBeta, feat);
            const float err  = yPrev - pred;

            sumW += w;
            sumR += w * err * err;
        }
    }

    if (sumW <= 0.0) return 0.0;
    return sumR / sumW;
}

//------------------------------------------------------------------------------
// Solve WLR on CURRENT frame.
//------------------------------------------------------------------------------
bool solveCurrentWLR(
    int2 ipos,
    int2 screenSize,
    out float outAlpha,
    out float outBeta[kFeatureDim])
{
    const float3 nC = loadNormal(gLinearZAndNormal, ipos);
    const float  zC = loadLinearZ(gLinearZAndNormal, ipos);
    const float3 aC = loadAlbedo(gAlbedo, ipos);

    float A[kBasisDim][kBasisDim];
    float b[kBasisDim];

    [unroll]
    for (int r = 0; r < kBasisDim; ++r)
    {
        b[r] = 0.0;
        [unroll]
        for (int c = 0; c < kBasisDim; ++c)
            A[r][c] = 0.0;
    }

    [loop]
    for (int oy = -kernelRadius; oy <= kernelRadius; ++oy)
    {
        [loop]
        for (int ox = -kernelRadius; ox <= kernelRadius; ++ox)
        {
            const int2 q = ipos + int2(ox, oy);
            if (!inBounds(q, screenSize)) continue;

            const float y = loadLogBrightness(gColor, q);

            const float3 nQ = loadNormal(gLinearZAndNormal, q);
            const float  zQ = loadLinearZ(gLinearZAndNormal, q);
            const float3 aQ = loadAlbedo(gAlbedo, q);

            float feat[kFeatureDim];
            float phi[kBasisDim];

            makeFeatureDiff(q, ipos, nQ, nC, zQ, zC, aQ, aC, feat);
            makeBasis(feat, phi);

            const float w = computeFeatureWeight(q, ipos, nQ, nC, zQ, zC, aQ, aC);
            if (w < minWeight) continue;

            [unroll]
            for (int r = 0; r < kBasisDim; ++r)
            {
                b[r] += w * phi[r] * y;

                [unroll]
                for (int c = 0; c < kBasisDim; ++c)
                    A[r][c] += w * phi[r] * phi[c];
            }
        }
    }

    [unroll]
    for (int i = 0; i < kBasisDim; ++i)
        A[i][i] += ridgeLambda;

    if (!solveLinearSystem10(A, b))
    {
        outAlpha = loadLogBrightness(gColor, ipos);
        [unroll]
        for (int i = 0; i < kFeatureDim; ++i) outBeta[i] = 0.0;
        return false;
    }

    outAlpha = b[0];
    [unroll]
    for (int i = 0; i < kFeatureDim; ++i) outBeta[i] = b[i + 1];

    return true;
}

//------------------------------------------------------------------------------
// Compute residual of CURRENT model on CURRENT frame.
//------------------------------------------------------------------------------
float computeCurrentResidual(
    int2 ipos,
    int2 screenSize,
    float alpha,
    const float beta[kFeatureDim])
{
    const float3 nC = loadNormal(gLinearZAndNormal, ipos);
    const float  zC = loadLinearZ(gLinearZAndNormal, ipos);
    const float3 aC = loadAlbedo(gAlbedo, ipos);

    float sumW = 0.0;
    float sumR = 0.0;

    [loop]
    for (int oy = -kernelRadius; oy <= kernelRadius; ++oy)
    {
        [loop]
        for (int ox = -kernelRadius; ox <= kernelRadius; ++ox)
        {
            const int2 q = ipos + int2(ox, oy);
            if (!inBounds(q, screenSize)) continue;

            const float y = loadLogBrightness(gColor, q);

            const float3 nQ = loadNormal(gLinearZAndNormal, q);
            const float  zQ = loadLinearZ(gLinearZAndNormal, q);
            const float3 aQ = loadAlbedo(gAlbedo, q);

            float feat[kFeatureDim];
            makeFeatureDiff(q, ipos, nQ, nC, zQ, zC, aQ, aC, feat);

            const float w = computeFeatureWeight(q, ipos, nQ, nC, zQ, zC, aQ, aC);
            if (w < minWeight) continue;

            const float pred = alpha + dotBeta(beta, feat);
            const float err  = y - pred;

            sumW += w;
            sumR += w * err * err;
        }
    }

    if (sumW <= 0.0) return 0.0;
    return sumR / sumW;
}

//------------------------------------------------------------------------------
// Main
//------------------------------------------------------------------------------
PS_OUT main(FullScreenPassVsOut vsOut)
{
    PS_OUT o;

    const int2 ipos = int2(vsOut.posH.xy);
    const int2 screenSize = getTextureDims(gAlbedo, 0);

    if (!inBounds(ipos, screenSize))
    {
        o.beta1 = 0.0;
        o.beta2 = 0.0;
        o.beta3 = 0.0;
        o.alphaResidual = 0.0;
        o.color = 0.0;
        o.albedo = 0.0;
        o.linearZAndNormal = 0.0;
        return o;
    }

    // Load previous coefficients and residual
    const float2 temp = gPrevAlphaResidual[ipos].xy;
    const float prevAlpha    = temp.x;
    const float prevResidual = temp.y;

    float prevBeta[kFeatureDim];
    unpackBeta(gPrevBeta1[ipos].rgb, gPrevBeta2[ipos].rgb, gPrevBeta3[ipos].rgb, prevBeta);

    // Compute shifted residual only
    const float shiftedResidual = computeShiftedResidual(ipos, screenSize, prevAlpha, prevBeta);

    const bool requireUpdate = abs(shiftedResidual - prevResidual) >= (eventThreshold * eventThreshold);
    // const bool requireUpdate = true;

    if (!requireUpdate)
    {
        o.beta1 = gPrevBeta1[ipos];
        o.beta2 = gPrevBeta2[ipos];
        o.beta3 = gPrevBeta3[ipos];
        o.alphaResidual = float4(prevAlpha, prevResidual, 0.0, 0.0);
        o.color = gPrevColor[ipos];
        o.albedo = gPrevAlbedo[ipos];
        o.linearZAndNormal  = gPrevLinearZAndNormal[ipos];
        return o;
    }

    // Refit current model
    float alpha;
    float beta[kFeatureDim];
    solveCurrentWLR(ipos, screenSize, alpha, beta);

    if(abs(alpha - prevAlpha) >= eventThreshold){
        // Save current residual of updated model
        const float residual = computeCurrentResidual(ipos, screenSize, alpha, beta);

        packBeta(beta, o.beta1, o.beta2, o.beta3);
        o.alphaResidual = float4(alpha, residual, (alpha > prevAlpha) ? 1.0 : -1.0, 0.0);
        o.color = gColor[ipos];
        o.albedo = gAlbedo[ipos];
        o.linearZAndNormal  = gLinearZAndNormal[ipos];
    } else {
        o.beta1 = gPrevBeta1[ipos];
        o.beta2 = gPrevBeta2[ipos];
        o.beta3 = gPrevBeta3[ipos];
        o.alphaResidual = float4(prevAlpha, prevResidual, 0.0, 0.0);
        o.color = gPrevColor[ipos];
        o.albedo = gPrevAlbedo[ipos];
        o.linearZAndNormal  = gPrevLinearZAndNormal[ipos];
    }
    
    return o;
}