import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.ShiftMapping.Charts.LocalPlaneChart;
import RenderPasses.Shared.Shaders.ShiftMapping.Charts.BarycentricChart;
import RenderPasses.Shared.Shaders.ShiftMapping.Charts.RayTraceHemisphereChart;
import RenderPasses.Shared.Shaders.ShiftMapping.Charts.CartesianRayChart;

import RenderPasses.Shared.Shaders.ShiftMapping.NewtonSolver;
import RenderPasses.Shared.Shaders.Utils.RayUtils;

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

#define SHIFT_MAPPING_NO 0
#define SHIFT_MAPPING_LOCAL_TANGENT 1
#define SHIFT_MAPPING_BARYCENTRIC 2
#define SHIFT_MAPPING_RAY_TRACE 3
#define SHIFT_MAPPING_AREA_ADAPTIVE 4
#define SHIFT_MAPPING_RAY_TRACE_CHART 5
#define SHIFT_MAPPING_RADIAL 6

cbuffer ShiftMappingCB
{
    float2 gGaugeAxis;
    uint gNewtonMaxIteration;
    float gNewtonRelativeTolerance;
}

// The host sets the gauge as a define (ShiftMappingConfig), so the Newton evaluations do not branch on it.
#ifndef SHIFT_MAPPING_GAUGE_MODE
#define SHIFT_MAPPING_GAUGE_MODE 0
#endif

GaugeMode getShiftGaugeMode()
{
    return GaugeMode(SHIFT_MAPPING_GAUGE_MODE);
}

struct ShiftMappingDebugInfo
{
    int iters;
    uint status;
#if DEBUG_NEWTON_ITERATIONS
    // Forward solve only: success before visibility, actual success, attempts, steps.
    uint4 newtonStats;
    // Pre-visibility successful solves only; identity mappings have zero displacement.
    float2 mappingDistance;
#endif
}

// The solver status describes the solve before endpoint/visibility validation.
void recordShiftSolve(NewtonResult result, inout ShiftMappingDebugInfo debugInfo)
{
    debugInfo.iters = result.iters;
    debugInfo.status = uint(result.status);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
}

HitInfo pathLengthAwareShiftMapping(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol,
    inout SampleGenerator sg
)
{
    // Invalid reconnection vertex.
    if(!x2.isValid()){
        jacobian = 0.0;
        return x2;
    }
    // Preserve the legacy constant-offset identity shortcut.
    if(abs(dt) < tol){
        jacobian = 1.0;
        return x2;
    }
    float2 a_const = gGaugeAxis;
    if(a_const.x == 0 && a_const.y == 0){
        float phi = M_2PI * sampleNext1D(sg);
        a_const = float2(cos(phi), sin(phi));
    }

#if SHIFT_MAPPING_METHOD == SHIFT_MAPPING_NO
    return shiftNone(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_LOCAL_TANGENT
    return shiftLocalTangent(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_BARYCENTRIC
    return shiftBarycentric(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE || SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE_CHART
    return shiftRayTrace(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_AREA_ADAPTIVE
    return shiftAreaAdaptive(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RADIAL
    return shiftRadial(x1, x2, x3, dt, jacobian, debuginfo, tol);
#endif
    jacobian = 1.0;
    return x2;
}

float3 shiftRayOrigin(ShadingData endpoint, bool isSurface, float3 destination)
{
    if (!isSurface) return endpoint.posW;
    return rayOriginToward(endpoint, destination - endpoint.posW);
}

// Recover the surface endpoint using a direction and distance computed from the
// SAME offset origin. There is no fixed world-space endpoint subtraction.
HitInfo traceShiftEndpoint(ShadingData endpoint, bool isSurface, float3 destination, float tol)
{
    float3 origin = shiftRayOrigin(endpoint, isSurface, destination);
    float3 segment = destination - origin;
    float distance = length(segment);
    if (!(distance > 1e-8f) || !isfinite(distance)) return HitInfo();
    SceneRayQuery<0> query;
    float hitT;
    HitInfo hit = query.traceRay(Ray(origin, segment / distance, 0.f, distance + 4.f * tol), hitT);
    if (!hit.isValid()) return HitInfo();
    if (hit.getType() != HitType::Triangle) return HitInfo();
    if (length(gScene.getVertexData(hit.getTriangleHit()).posW - destination) > 4.f * tol) return HitInfo();
    return hit;
}

HitInfo shiftAreaAdaptive(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    const float areaThreshold = 0.01f;
    TriangleHit original = x2.getTriangleHit();
    bool usePlane = gScene.getFaceAreaW(original.instanceID, original.primitiveIndex) > areaThreshold;
    HitInfo hit;
    if (usePlane)
        hit = shiftLocalTangent(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
    else
        hit = shiftRayTrace(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);

    if (!(jacobian > 0.f) || !hit.isValid()) { jacobian = 0.f; return x2; }
    if (hit.getType() != HitType::Triangle) { jacobian = 0.f; return x2; }
    TriangleHit shifted = hit.getTriangleHit();
    bool shiftedUsesPlane = gScene.getFaceAreaW(shifted.instanceID, shifted.primitiveIndex) > areaThreshold;
    // Both endpoints must select the same surface operation.
    if (shiftedUsesPlane != usePlane) { jacobian = 0.f; return x2; }
    return hit;
}

HitInfo shiftNone(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    debuginfo.iters = 0;
    debuginfo.status = 0;
    jacobian = 1.0;
    return x2;
}

HitInfo shiftLocalTangent(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    VertexData v2 = gScene.getVertexData(x2.getTriangleHit());
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    float3 x = v2.posW;
    float3 n = v2.faceNormalW;

    float3 bitangent = perp_stark_onb(n);
    float3 tangent = cross(bitangent, n);

    LocalPlaneChart ops = LocalPlaneChart(p1, p2, x, tangent, bitangent);
    float2 xi = float2(0, 0);
    NewtonResult result = solveShiftNewton(ops, xi, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    recordShiftSolve(result, debuginfo);
    jacobian = 0.f;
    if (result.status != NewtonResultStatus::SUCCESS) return x2;

    float3 x_prime = ops.X(result.xi_prime);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.mappingDistance = float2(length(result.xi_prime - xi), length(x_prime - x));
#endif
    HitInfo hit = traceShiftEndpoint(x3, true, x_prime, tol);
    if (!hit.isValid()) return x2;
    VertexData shifted = gScene.getVertexData(hit.getTriangleHit());
    if (!(abs(dot(shifted.posW - x, n)) <= tol && dot(shifted.faceNormalW, n) > 0.999999f)) return x2;

    jacobian = result.detJ;
    return hit;
}

/// Path length |p1 - X| + |p2 - X| at X, and its derivative along the unit direction u.
float pathLengthAlong(float3 p1, float3 p2, float3 X, float3 u, out float slope)
{
    float3 r1 = p1 - X;
    float3 r2 = p2 - X;
    float d1 = length(r1);
    float d2 = length(r2);
    slope = -dot(u, r1 / d1 + r2 / d2);
    return d1 + d2;
}

/** Radial shift: moves x2's vertex along the ray from m, the minimum of the path length |p1 - X| + |p2 - X| on the
    vertex's plane, until the path length changes by dt. The path length increases along every ray from m, so the
    target has one solution on the ray (a 1D Newton search with bisection), and the +dt and -dt shifts are exact
    inverses: the partner lies on the same ray, and m depends only on the plane and the two fixed vertices. m is
    where the segment p1 -> p2 crosses the plane, with p2 mirrored when both are on the same side. The shifted
    vertex must be the first hit from x3 on the same plane. The jacobian is the area ratio of the polar map
    (r, angle) -> (s, angle), (s / r) * (slope(r) / slope(s)). The gauge settings are not used.
*/
HitInfo shiftRadial(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    jacobian = 0.f;
    debuginfo.iters = 0;
    debuginfo.status = uint(NewtonResultStatus::NO_CONVERGE);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(0, 0, 1, 0);
#endif
    VertexData vertex = gScene.getVertexData(x2.getTriangleHit());
    float3 n = normalize(vertex.faceNormalW);
    float3 x = vertex.posW;
    float3 p1 = x1.posW;
    float3 p2 = x3.posW;

    // m: where the segment p1 -> p2 crosses the plane, with p2 mirrored when both are on the same side.
    float h1 = dot(p1 - x, n);
    float h2 = dot(p2 - x, n);
    bool sameSide = h1 * h2 > 0.f;
    float3 q2 = sameSide ? p2 - 2.f * h2 * n : p2;
    float hq2 = sameSide ? -h2 : h2;
    if (!(abs(h1 - hq2) > 1e-12f)) return x2;
    float3 m = p1 + (h1 / (h1 - hq2)) * (q2 - p1);
    m -= dot(m - x, n) * n; // onto the plane

    float3 offset = x - m;
    offset -= dot(offset, n) * n;
    float r = length(offset);
    if (!(r > 1e-6f)) return x2;
    float3 u = offset / r;

    float slopeStart;
    float target = pathLengthAlong(p1, p2, m + r * u, u, slopeStart) + dt;
    if (!(slopeStart > 0.f)) return x2;

    // Bracket the root on the ray, then refine with Newton, falling back to bisection.
    float lo, hi;
    if (dt < 0.f)
    {
        float slopeAtMinimum;
        if (!(target > pathLengthAlong(p1, p2, m, u, slopeAtMinimum))) return x2; // shorter than the minimum
        lo = 0.f;
        hi = r;
    }
    else
    {
        lo = r;
        hi = r + dt;
        float slope;
        uint grow = 0;
        while (pathLengthAlong(p1, p2, m + hi * u, u, slope) < target && grow++ < 40)
            hi = lo + 2.f * (hi - lo);
        if (grow > 40) return x2;
    }
    float s = r;
    float slope = slopeStart;
    bool converged = false;
    for (uint iteration = 0; iteration < 60; iteration++)
    {
        debuginfo.iters = int(iteration + 1);
        float residual = pathLengthAlong(p1, p2, m + s * u, u, slope) - target;
        if (abs(residual) < tol) { converged = true; break; }
        if (residual > 0.f) hi = s; else lo = s;
        float next = slope > 0.f ? s - residual / slope : 0.5f * (lo + hi);
        s = (next > lo && next < hi) ? next : 0.5f * (lo + hi);
    }
    if (!converged || !(slope > 0.f) || !(s > 0.f)) return x2;

    // Polar map (r, angle) -> (s, angle): dA' / dA = (s / r) * (ds / dr), ds / dr = slope(r) / slope(s).
    float3 shiftedPosition = m + s * u;
    HitInfo shifted = traceShiftEndpoint(x3, true, shiftedPosition, tol);
    if (!shifted.isValid()) return x2;
    VertexData shiftedVertex = gScene.getVertexData(shifted.getTriangleHit());
    if (!(abs(dot(shiftedVertex.posW - x, n)) <= tol && dot(normalize(shiftedVertex.faceNormalW), n) > 0.999999f))
        return x2;
    jacobian = (s / r) * (slopeStart / slope);
    debuginfo.status = uint(NewtonResultStatus::SUCCESS);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(1, 0, 1, debuginfo.iters);
    debuginfo.mappingDistance = float2(0.f, length(shiftedPosition - x));
#endif
    return shifted;
}

HitInfo shiftBarycentric(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    TriangleHit triHit = x2.getTriangleHit();
    float3 triposW[3];
    gScene.getVertexPositionsW(triHit.instanceID, triHit.primitiveIndex, triposW);

    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    BarycentricChart ops = BarycentricChart(p1, p2, triposW[0], triposW[1], triposW[2]);
    NewtonResult result = solveShiftNewton(ops, triHit.barycentrics, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    recordShiftSolve(result, debuginfo);
    jacobian = 0.f;
    if (result.status != NewtonResultStatus::SUCCESS) return x2;
    float2 bary = result.xi_prime;
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.mappingDistance = float2(length(bary - triHit.barycentrics), length(ops.X(bary) - ops.X(triHit.barycentrics)));
#endif
    // Keep the original strict interior test (triangle edges are excluded).
    if (!(bary.x > 0.f && bary.y > 0.f && bary.x + bary.y < 1.f)) return x2;

    HitInfo hit = traceShiftEndpoint(x3, true, ops.X(bary), tol);
    if (!hit.isValid()) return x2;
    TriangleHit traced = hit.getTriangleHit();
    if (traced.instanceID.index != triHit.instanceID.index || traced.primitiveIndex != triHit.primitiveIndex) return x2;

    jacobian = result.detJ;
    triHit.barycentrics = bary;
    return HitInfo(triHit);
}

HitInfo shiftRayTrace(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    VertexData v2 = gScene.getVertexData(x2.getTriangleHit());
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    const float3 p2o = x3.computeRayOrigin();
    float3 x = v2.posW;
    float3 n = v2.faceNormalW;

    float3 n2 = x3.getOrientedFaceNormal();
    float3 b2 = perp_stark_onb(n2);
    float3 t2 = cross(b2, n2);

    RayTraceHemisphereChart ops = RayTraceHemisphereChart(p1, p2, p2o, t2, b2, n2);
    ops.hit = x2;
    ops.hitT = length(v2.posW - p2o);

    float3 dir = normalize(v2.posW - p2o);
    float3 local = float3(dot(t2, dir), dot(b2, dir), dot(n2, dir));
#if SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE_CHART
    if (!(local.z > 1e-6f)) { jacobian = 0.f; return x2; }
    ops.useCartesianChart = true;
    float2 xi = local.xy / local.z;
#else
    float2 xi = inverse_sample_hemisphere_preserve_area(local);
#endif

    NewtonResult result = solveShiftNewton(ops, xi, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    recordShiftSolve(result, debuginfo);
    HitInfo new_sample = x2;

    if(result.status == NewtonResultStatus::SUCCESS && ops.hit.isValid()){
        new_sample = ops.hit;
        VertexData vnew = gScene.getVertexData(new_sample.getTriangleHit());
#if DEBUG_NEWTON_ITERATIONS
        debuginfo.mappingDistance = float2(length(result.xi_prime - xi), length(vnew.posW - x));
#endif

        float L0 = length(p2o - x);
        float L = length(p2o - vnew.posW);
        float3 d0 = normalize(p2o - x);
        float3 d = normalize(p2o - vnew.posW);

        float G = (L0 * L0) < 1e-9 ? 0.0 : abs(dot(n, d0)) / (L0 * L0);
        float G2 = (L * L) < 1e-9 ? 0.0 : abs(dot(vnew.faceNormalW, d)) / (L * L);
        if(G < 1e-9 || G2 < 1e-9){
            jacobian = 0;
        } else {
            jacobian = result.detJ * G / G2;
#if SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE_CHART
            jacobian *= CartesianRayChart::solidAngleDensity(result.xi_prime) / CartesianRayChart::solidAngleDensity(xi);
#endif
        }
        if (!(jacobian > 0.f) || !isfinite(jacobian)){
            jacobian = 0.0;
        }
        return new_sample;
    }
    jacobian = 0;
    return new_sample;
}
