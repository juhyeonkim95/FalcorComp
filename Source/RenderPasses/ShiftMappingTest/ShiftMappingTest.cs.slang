/** Bijectivity test of the path-length-aware shift mappings (ShiftMappingTest.cpp), in the configuration of ReSTIR's
    spatial reuse. Per pixel p: the target path's preceding vertex a_t is p's primary hit; the source's a_s is the primary
    hit of a neighbor q within gNeighborRadius pixels; x is the first hit of a cosine-sampled ray from a_s; y is the
    first hit of a cosine-sampled ray from x, or the camera (a collocated point light) with gNextIsLight. The source path
    camera -> a_s -> x -> y is shifted to camera -> a_t -> x' -> y with equal total lengths plus an extra length change
    delta in [-gLengthChange, gLengthChange]: ell_t(x') = ell_s(x) + |a_s - camera| - |a_t - camera| + delta. The reverse
    shift then maps x' back. Not for release.
*/
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import RenderPasses.Shared.Shaders.Utils.Frames;
import RenderPasses.Shared.Shaders.ShiftMapping.ShiftMapping;
import RenderPasses.Shared.Shaders.ShiftMapping.NewtonSolver;

cbuffer CB
{
    uint2 gFrameDim;
    uint gSeed;
    float gLengthChange;
    float gNeighborRadius;
    uint gNextIsLight;
    float gEpsilon;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

RWTexture2D<float4> gShift;       // (forward ok, |x'' - x| or -1 when the reverse fails, |J_f J_r - 1|, |x' - x|)
// (J_f, plane margin (see main), J_finite-difference / J_f - 1 or -1, condition offset)
RWTexture2D<float4> gShiftValues;
RWTexture2D<float4> gShiftStatus; // (forward status, forward iterations, reverse status, reverse iterations)

ShadingData pointOnly(float3 p)
{
    ShadingData sd = {};
    sd.posW = p;
    return sd;
}

// The first triangle hit of a cosine-sampled ray from `from`.
bool sampleNext(ShadingData from, inout SampleGenerator sg, out HitInfo hit, out ShadingData next)
{
    next = {};
    float pdf;
    float3 local = sample_cosine_hemisphere_concentric(sampleNext2D(sg), pdf);
    float3 n = from.getOrientedFaceNormal();
    float3 b = perp_stark_onb(n);
    float3 t = cross(b, n);
    float3 dir = normalize(local.x * t + local.y * b + local.z * n);
    SceneRayQuery<0> query;
    float hitT;
    float3 origin = from.computeRayOrigin();
    hit = query.traceRay(Ray(origin, dir, 0.f, FLT_MAX), hitT);
    if (!hit.isValid() || hit.getType() != HitType::Triangle) return false;
    next = loadShadingData(hit, origin, dir);
    return true;
}

// Shift x (on the source path aSource -> x -> y) to the target path aTarget -> x' -> y with
// ell_t(x') = ell_s(x) + offset.
HitInfo shiftOnce(float3 aTarget, float3 aSource, HitInfo xHit, VertexData xv, ShadingData y, float offset,
    out float jacobian, out VertexData shifted, out ShiftMappingDebugInfo debugInfo, inout SampleGenerator sg)
{
    ShadingData x1 = pointOnly(aTarget);
    ShiftSource source = makeShiftSource(aSource, y, x1, y);
    ShiftLengthCondition condition = { 1.f, 0.f, offset, 0.f, 0.f }; // ell_t(x') = ell_s(x) + offset
    debugInfo = {};
    return pathLengthAwareShiftMapping(x1, xHit, xv, y, source, condition, jacobian, shifted, debugInfo, sg);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gShift[pixel] = float4(0.f);
    gShiftValues[pixel] = float4(0.f);
    gShiftStatus[pixel] = float4(-1.f);

    SampleGenerator sg = SampleGenerator(pixel, gSeed);
    float3 camera = gScene.camera.getPosition();

    // Target and source prefixes: the primary hits of p and of a neighbor q.
    HitInfo targetHit = HitInfo(gVBuffer[pixel]);
    if (!targetHit.isValid() || targetHit.getType() != HitType::Triangle) return;
    float2 u = sampleNext2D(sg);
    float radius = gNeighborRadius * sqrt(u.x);
    int2 neighbor = int2(pixel) + int2(round(radius * float2(cos(M_2PI * u.y), sin(M_2PI * u.y))));
    if (any(neighbor < 0) || any(neighbor >= int2(gFrameDim))) return;
    HitInfo sourceHit = HitInfo(gVBuffer[uint2(neighbor)]);
    if (!sourceHit.isValid() || sourceHit.getType() != HitType::Triangle) return;
    ShadingData aTarget = loadShadingData(targetHit, camera, getPrimaryRayDir(pixel, gFrameDim, gViewW));
    ShadingData aSource = loadShadingData(sourceHit, camera, getPrimaryRayDir(uint2(neighbor), gFrameDim, gViewW));

    // The source path's reconnection vertex x and its next vertex y.
    HitInfo xHit;
    ShadingData xs;
    if (!sampleNext(aSource, sg, xHit, xs)) return;
    VertexData xv = gScene.getVertexData(xHit.getTriangleHit());
    ShadingData y;
    if (gNextIsLight != 0)
    {
        // As ReSTIR's point light: the collocated light's direction is the camera's view direction. As in a sampled
        // path, the segment x -> light is unoccluded.
        y = pointOnly(camera);
        y.frontFacing = true;
        y.faceN = normalize(gScene.camera.data.cameraW);
        float3 origin = xs.computeRayOrigin();
        float3 toLight = camera - origin;
        float distance = length(toLight);
        SceneRayQuery<0> query;
        if (!query.traceVisibilityRay(Ray(origin, toLight / distance, 0.f, distance * (1.f - 1e-4f)))) return;
    }
    else
    {
        HitInfo yHit;
        if (!sampleNext(xs, sg, yHit, y)) return;
    }

    float delta = (2.f * sampleNext1D(sg) - 1.f) * gLengthChange;
    float offset = length(aSource.posW - camera) - length(aTarget.posW - camera) + delta;

    // The needed length minus the shortest a_t -> p -> y over x's plane (mirror construction): negative where no point
    // of the plane has the needed length, so a plane chart has no solution.
    float3 n = xs.faceN;
    float sideA = dot(aTarget.posW - xs.posW, n), sideY = dot(y.posW - xs.posW, n);
    float3 yMirror = sideA * sideY > 0.f ? y.posW - 2.f * sideY * n : y.posW;
    float neededLength = length(aSource.posW - xs.posW) + length(y.posW - xs.posW) + offset;
    float planeMargin = neededLength - length(aTarget.posW - yMirror);

    float jacobian;
    VertexData shifted;
    ShiftMappingDebugInfo forwardInfo;
    HitInfo shiftedHit = shiftOnce(aTarget.posW, aSource.posW, xHit, xv, y, offset, jacobian, shifted, forwardInfo, sg);
    bool ok = jacobian > 0.f && shiftedHit.isValid();
    gShiftStatus[pixel] = float4(float(forwardInfo.status), float(forwardInfo.iters), -1.f, -1.f);
    gShiftValues[pixel] = float4(jacobian, planeMargin, -1.f, offset);
    if (!ok) return;

    // The reverse shift: x' on a_t -> x' -> y back to a_s -> x -> y, ell_s(x) = ell_t(x') - offset.
    float jacobianBack;
    VertexData back;
    ShiftMappingDebugInfo reverseInfo;
    HitInfo backHit = shiftOnce(aSource.posW, aTarget.posW, shiftedHit, shifted, y, -offset, jacobianBack, back,
        reverseInfo, sg);
    bool backOk = backHit.isValid() && jacobianBack > 0.f;
    float roundTrip = backOk ? length(back.posW - xv.posW) : -1.f;
    gShiftStatus[pixel] = float4(float(forwardInfo.status), float(forwardInfo.iters), float(reverseInfo.status),
        float(reverseInfo.iters));

    // Finite-difference Jacobian: shift x moved by +-eps along two barycentric directions of its triangle (central
    // differences) and compare the areas spanned before and after.
    float jacobianFdError = -1.f;
    TriangleHit tri = xHit.getTriangleHit();
    float eps = gEpsilon;
    float2 bary = tri.barycentrics;
    if (gEpsilon > 0.f && bary.x > eps && bary.y > eps && bary.x + bary.y < 1.f - eps)
    {
        float3 before[4], after[4];
        float2 offsets[4] = { float2(eps, 0.f), float2(-eps, 0.f), float2(0.f, eps), float2(0.f, -eps) };
        bool complete = true;
        for (uint i = 0; i < 4; i++)
        {
            TriangleHit moved = tri;
            moved.barycentrics = bary + offsets[i];
            VertexData mv = gScene.getVertexData(moved);
            float jm;
            VertexData sm;
            ShiftMappingDebugInfo info;
            HitInfo h = shiftOnce(aTarget.posW, aSource.posW, HitInfo(moved), mv, y, offset, jm, sm, info, sg);
            if (!(jm > 0.f) || !h.isValid()) { complete = false; break; }
            before[i] = mv.posW;
            after[i] = sm.posW;
        }
        if (complete)
        {
            float areaBefore = length(cross(before[0] - before[1], before[2] - before[3]));
            float areaAfter = length(cross(after[0] - after[1], after[2] - after[3]));
            jacobianFdError = abs(areaAfter / areaBefore / jacobian - 1.f);
        }
    }
    gShiftValues[pixel] = float4(jacobian, planeMargin, jacobianFdError, offset);
    gShift[pixel] = float4(1.f, roundTrip, backOk ? abs(jacobian * jacobianBack - 1.f) : -1.f,
        length(shifted.posW - xv.posW));
}
