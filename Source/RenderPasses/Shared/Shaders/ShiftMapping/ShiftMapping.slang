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
    float gRayChartMaxDisplacement; // 0 disables; see shiftRayTrace.
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

// The source path's endpoints around the moved vertex: p1 = a_s (preceding vertex) and next = y_s (next vertex,
// p2 = its position). When the source path comes from another pixel or frame, its path length |a_s - X| + |y_s - X|
// differs from the target's, and so do its gradient and Hessian at the source point, which the gauge and the
// Jacobian use. A chart built from y (directions from y) is a different function for the source and the target when
// y_s differs from y_t (a re-lit suffix in a dynamic scene); charts built from x's plane or triangle never differ.
struct ShiftSource
{
    float3 p1;
    float3 p2;
    ShadingData next;
    bool distinct;     // (a_s, y_s) differ from (a_t, y_t); false: the single-length solve.
    bool distinctNext; // y_s differs from y_t (position or oriented normal): charts built from y differ.
};

ShiftSource makeShiftSource(float3 p1, ShadingData next, ShadingData x1, ShadingData x3)
{
    bool distinctNext = any(next.posW != x3.posW) || any(next.getOrientedFaceNormal() != x3.getOrientedFaceNormal());
    ShiftSource source = { p1, next.posW, next, any(p1 != x1.posW) || distinctNext, distinctNext };
    return source;
}

// The solver status describes the solve before endpoint/visibility validation.
void recordShiftSolve(NewtonResult result, inout ShiftMappingDebugInfo debugInfo)
{
    debugInfo.iters = result.iters;
    debugInfo.status = uint(result.status);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::Success, 0, 1, result.iters);
#endif
}

// Moves the source path's vertex x2 to x2' on the target path (x1 -> x2' -> x3) so that the target path meets the
// source path's length condition (ShiftLengthCondition):
//     ell_t(x2') = K (ell_s(x2) + rest_s - g_s) + g_t - rest_t,
// with ell_s(x2) = |source.p1 - x2| + |source.p2 - x2| and ell_t(x2') = |x1 - x2'| + |x3 - x2'|. With source endpoints
// that differ from the target's, the Jacobian uses the source length's gradient at x2.
HitInfo pathLengthAwareShiftMapping(
    ShadingData x1, // preceding vertex of the target path
    HitInfo x2, // vertex to shift
    VertexData v2, // x2's vertex data
    ShadingData x3, // fixed next vertex (surface or point light) of the target path
    ShiftSource source,
    ShiftLengthCondition condition,
    out float jacobian,
    out VertexData shiftedVertex, // the returned hit's vertex data
    inout ShiftMappingDebugInfo debuginfo,
    inout SampleGenerator sg
)
{
    shiftedVertex = v2;
    // Invalid reconnection vertex.
    if(!x2.isValid()){
        jacobian = 0.0;
        return x2;
    }
    // dt: how much the target path through the unmoved x2 must change, ell_t(x2') - ell_t(x2). It sets the tolerance.
    float3 x = v2.posW;
    float dt = condition.targetLength(length(source.p1 - x) + length(source.p2 - x))
        - (length(x1.posW - x) + length(x3.posW - x));
    float tol = max(abs(dt) * gNewtonRelativeTolerance, 1e-6f);
    // Identity shortcut: only valid when the source and target lengths are the same function of x2.
    if(abs(dt) < tol && !source.distinct){
        jacobian = 1.0;
        return x2;
    }
    float2 a_const = gGaugeAxis;
    if(a_const.x == 0 && a_const.y == 0){
        float phi = M_2PI * sampleNext1D(sg);
        a_const = float2(cos(phi), sin(phi));
    }

#if SHIFT_MAPPING_METHOD == SHIFT_MAPPING_NO
    return shiftNone(x2, jacobian, debuginfo);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_LOCAL_TANGENT
    return shiftLocalTangent(x1, x2, v2, x3, source, condition, a_const, jacobian, shiftedVertex, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_BARYCENTRIC
    return shiftBarycentric(x1, x2, v2, x3, source, condition, a_const, jacobian, shiftedVertex, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE || SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE_CHART
    return shiftRayTrace(x1, x2, v2, x3, source, condition, a_const, jacobian, shiftedVertex, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_AREA_ADAPTIVE
    return shiftAreaAdaptive(x1, x2, v2, x3, source, condition, a_const, jacobian, shiftedVertex, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RADIAL
    return shiftRadial(x1, x2, v2, x3, source, condition, jacobian, shiftedVertex, debuginfo, tol);
#endif
    jacobian = 1.0;
    return x2;
}

// Same source and target endpoints, with a fixed length change: ell(x2') = ell(x2) + dt (e.g. antithetic sampling).
HitInfo pathLengthAwareShiftMapping(ShadingData x1, HitInfo x2, VertexData v2, ShadingData x3, float dt,
    out float jacobian, out VertexData shiftedVertex, inout ShiftMappingDebugInfo debuginfo, inout SampleGenerator sg)
{
    ShiftSource source = { x1.posW, x3.posW, x3, false, false };
    return pathLengthAwareShiftMapping(x1, x2, v2, x3, source, makeLengthOffset(dt), jacobian, shiftedVertex, debuginfo,
        sg);
}

float3 shiftRayOrigin(ShadingData endpoint, bool isSurface, float3 destination)
{
    if (!isSurface) return endpoint.posW;
    return rayOriginToward(endpoint, destination - endpoint.posW);
}

// Recover the surface endpoint using a direction and distance computed from the
// SAME offset origin. There is no fixed world-space endpoint subtraction.
HitInfo traceShiftEndpoint(ShadingData endpoint, bool isSurface, float3 destination, float tol, out VertexData vertex)
{
    vertex = {};
    float3 origin = shiftRayOrigin(endpoint, isSurface, destination);
    float3 segment = destination - origin;
    float distance = length(segment);
    if (!(distance > 1e-8f) || !isfinite(distance)) return HitInfo();
    SceneRayQuery<0> query;
    float hitT;
    HitInfo hit = query.traceRay(Ray(origin, segment / distance, 0.f, distance + 4.f * tol), hitT);
    if (!hit.isValid()) return HitInfo();
    if (hit.getType() != HitType::Triangle) return HitInfo();
    vertex = gScene.getVertexData(hit.getTriangleHit());
    if (length(vertex.posW - destination) > 4.f * tol) return HitInfo();
    return hit;
}

HitInfo shiftAreaAdaptive(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    VertexData v2, // x2's vertex data
    ShadingData x3, // fixed next vertex (surface or point light)
    ShiftSource source,
    ShiftLengthCondition condition,
    float2 a_const,
    out float jacobian,
    out VertexData shiftedVertex, // the returned hit's vertex data
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    shiftedVertex = v2;
    const float areaThreshold = 0.01f;
    TriangleHit original = x2.getTriangleHit();
    bool usePlane = gScene.getFaceAreaW(original.instanceID, original.primitiveIndex) > areaThreshold;
    HitInfo hit;
    if (usePlane)
        hit = shiftLocalTangent(x1, x2, v2, x3, source, condition, a_const, jacobian, shiftedVertex, debuginfo, tol);
    else
        hit = shiftRayTrace(x1, x2, v2, x3, source, condition, a_const, jacobian, shiftedVertex, debuginfo, tol);

    if (!(jacobian > 0.f) || !hit.isValid()) { jacobian = 0.f; shiftedVertex = v2; return x2; }
    if (hit.getType() != HitType::Triangle) { jacobian = 0.f; shiftedVertex = v2; return x2; }
    TriangleHit shifted = hit.getTriangleHit();
    bool shiftedUsesPlane = gScene.getFaceAreaW(shifted.instanceID, shifted.primitiveIndex) > areaThreshold;
    // Both endpoints must select the same surface operation.
    if (shiftedUsesPlane != usePlane) { jacobian = 0.f; shiftedVertex = v2; return x2; }
    return hit;
}

HitInfo shiftNone(HitInfo x2, out float jacobian, inout ShiftMappingDebugInfo debuginfo)
{
    debuginfo.iters = 0;
    debuginfo.status = 0;
    jacobian = 1.0;
    return x2;
}

HitInfo shiftLocalTangent(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    VertexData v2, // x2's vertex data
    ShadingData x3, // fixed next vertex (surface or point light)
    ShiftSource source,
    ShiftLengthCondition condition,
    float2 a_const,
    out float jacobian,
    out VertexData shiftedVertex, // the returned hit's vertex data
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    shiftedVertex = v2;
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    float3 x = v2.posW;
    float3 n = v2.faceNormalW;

    float3 bitangent = perp_stark_onb(n);
    float3 tangent = cross(bitangent, n);

    LocalPlaneChart ops = LocalPlaneChart(p1, p2, x, tangent, bitangent);
    LocalPlaneChart sourceOps = LocalPlaneChart(source.p1, source.p2, x, tangent, bitangent);
    float2 xi = float2(0, 0);
    // The plane chart depends only on x's plane, so it is the same function for the source and the target.
    NewtonResult result = solveShiftNewton(ops, sourceOps, source.distinct, false, condition, xi, getShiftGaugeMode(),
        a_const, gNewtonMaxIteration, tol);
    recordShiftSolve(result, debuginfo);
    jacobian = 0.f;
    if (result.status != NewtonResultStatus::Success) return x2;

    float3 x_prime = ops.X(result.xi_prime);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.mappingDistance = float2(length(result.xi_prime - xi), length(x_prime - x));
#endif
    VertexData traced;
    HitInfo hit = traceShiftEndpoint(x3, true, x_prime, tol, traced);
    if (!hit.isValid()) return x2;
    if (!(abs(dot(traced.posW - x, n)) <= tol && dot(traced.faceNormalW, n) > 0.999999f)) return x2;

    jacobian = result.detJ;
    shiftedVertex = traced;
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

/// Minimum m of |p1 - X| + |p2 - X| over the plane through x with normal n: where the segment p1 -> p2 crosses the
/// plane, with p2 mirrored when both are on the same side. False if the segment is parallel to the plane.
bool radialCenter(float3 p1, float3 p2, float3 x, float3 n, out float3 m)
{
    m = x;
    float h1 = dot(p1 - x, n);
    float h2 = dot(p2 - x, n);
    bool sameSide = h1 * h2 > 0.f;
    float3 q2 = sameSide ? p2 - 2.f * h2 * n : p2;
    float hq2 = sameSide ? -h2 : h2;
    if (!(abs(h1 - hq2) > 1e-12f)) return false;
    m = p1 + (h1 / (h1 - hq2)) * (q2 - p1);
    m -= dot(m - x, n) * n; // onto the plane
    return true;
}

/// Solves |p1 - X| + |p2 - X| = target for X = m + s u, s > 0 (m the minimum on the plane, so the length increases
/// with s), by Newton with bisection from s = start. slope is the derivative at the solution.
bool solveRadial(float3 p1, float3 p2, float3 m, float3 u, float target, float start, float tol,
    inout ShiftMappingDebugInfo debuginfo, out float s, out float slope)
{
    s = start;
    slope = 0.f;
    float slopeAtMinimum;
    if (!(target > pathLengthAlong(p1, p2, m, u, slopeAtMinimum))) return false; // shorter than the minimum
    float lo = 0.f;
    float hi = max(start, 1e-4f);
    uint grow = 0;
    while (pathLengthAlong(p1, p2, m + hi * u, u, slope) < target && grow++ < 40)
        hi *= 2.f;
    if (grow > 40) return false;
    s = clamp(start, lo, hi);
    for (uint iteration = 0; iteration < 60; iteration++)
    {
        debuginfo.iters = int(iteration + 1);
        float residual = pathLengthAlong(p1, p2, m + s * u, u, slope) - target;
        if (abs(residual) < tol) return slope > 0.f && s > 0.f;
        if (residual > 0.f) hi = s; else lo = s;
        float next = slope > 0.f ? s - residual / slope : 0.5f * (lo + hi);
        s = (next > lo && next < hi) ? next : 0.5f * (lo + hi);
    }
    return false;
}

/** Radial shift: moves x2's vertex along the ray from m, the minimum of the path length |p1 - X| + |p2 - X| on the
    vertex's plane, until the path length meets the length condition (a change dt with the same endpoints). The path
    length increases along every ray from m, so the target has one solution on the ray (a 1D Newton search with
    bisection), and the +dt and -dt shifts are exact inverses: the partner lies on the same ray, and m depends only on
    the plane and the two fixed vertices. m is where the segment p1 -> p2 crosses the plane, with p2 mirrored when
    both are on the same side. The shifted vertex must be the first hit from x3 on the same plane. The jacobian is the
    area ratio of the polar map (r, angle) -> (s, angle), (s / r) * (slope(r) / slope(s)). The gauge settings are not
    used.
    With a distinct source, the angle is kept about each path's own minimum: x = m_s + r u and x' = m_t + s u with
    ell_t(x') = condition.targetLength(ell_s(x)), slope(r) the source length's slope, slope(s) the target's; the reverse
    shift then maps x' back to x.
*/
HitInfo shiftRadial(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    VertexData v2, // x2's vertex data
    ShadingData x3, // fixed next vertex (surface or point light)
    ShiftSource source,
    ShiftLengthCondition condition,
    out float jacobian,
    out VertexData shiftedVertex, // the returned hit's vertex data
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    shiftedVertex = v2;
    jacobian = 0.f;
    debuginfo.iters = 0;
    debuginfo.status = uint(NewtonResultStatus::NoConverge);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(0, 0, 1, 0);
#endif
    float3 n = normalize(v2.faceNormalW);
    float3 x = v2.posW;
    float3 p1 = x1.posW;
    float3 p2 = x3.posW;

    if (source.distinct)
    {
        float3 ms, mt;
        if (!radialCenter(source.p1, source.p2, x, n, ms) || !radialCenter(p1, p2, x, n, mt)) return x2;
        float3 offset = x - ms;
        offset -= dot(offset, n) * n;
        float r = length(offset);
        if (!(r > 1e-6f)) return x2;
        float3 u = offset / r;
        float slopeSource;
        float target = condition.targetLength(pathLengthAlong(source.p1, source.p2, x, u, slopeSource));
        if (!(slopeSource > 0.f)) return x2;
        float s, slope;
        if (!solveRadial(p1, p2, mt, u, target, r, tol, debuginfo, s, slope)) return x2;
        float3 shiftedPosition = mt + s * u;
        VertexData traced;
        HitInfo shifted = traceShiftEndpoint(x3, true, shiftedPosition, tol, traced);
        if (!shifted.isValid()) return x2;
        if (!(abs(dot(traced.posW - x, n)) <= tol && dot(normalize(traced.faceNormalW), n) > 0.999999f))
            return x2;
        shiftedVertex = traced;
        jacobian = (s / r) * (slopeSource / slope);
        debuginfo.status = uint(NewtonResultStatus::Success);
#if DEBUG_NEWTON_ITERATIONS
        debuginfo.newtonStats = uint4(1, 0, 1, debuginfo.iters);
        debuginfo.mappingDistance = float2(0.f, length(shiftedPosition - x));
#endif
        return shifted;
    }

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
    float startLength = pathLengthAlong(p1, p2, m + r * u, u, slopeStart);
    float target = condition.targetLength(startLength);
    float dt = target - startLength;
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
    VertexData traced;
    HitInfo shifted = traceShiftEndpoint(x3, true, shiftedPosition, tol, traced);
    if (!shifted.isValid()) return x2;
    if (!(abs(dot(traced.posW - x, n)) <= tol && dot(normalize(traced.faceNormalW), n) > 0.999999f))
        return x2;
    shiftedVertex = traced;
    jacobian = (s / r) * (slopeStart / slope);
    debuginfo.status = uint(NewtonResultStatus::Success);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(1, 0, 1, debuginfo.iters);
    debuginfo.mappingDistance = float2(0.f, length(shiftedPosition - x));
#endif
    return shifted;
}

HitInfo shiftBarycentric(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    VertexData v2, // x2's vertex data
    ShadingData x3, // fixed next vertex (surface or point light)
    ShiftSource source,
    ShiftLengthCondition condition,
    float2 a_const,
    out float jacobian,
    out VertexData shiftedVertex, // the returned hit's vertex data
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    shiftedVertex = v2;
    TriangleHit triHit = x2.getTriangleHit();
    float3 triposW[3];
    gScene.getVertexPositionsW(triHit.instanceID, triHit.primitiveIndex, triposW);

    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    BarycentricChart ops = BarycentricChart(p1, p2, triposW[0], triposW[1], triposW[2]);
    BarycentricChart sourceOps = BarycentricChart(source.p1, source.p2, triposW[0], triposW[1], triposW[2]);
    // The barycentric chart depends only on x's triangle (x' must stay on it): the same for source and target.
    NewtonResult result = solveShiftNewton(ops, sourceOps, source.distinct, false, condition, triHit.barycentrics,
        getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    recordShiftSolve(result, debuginfo);
    jacobian = 0.f;
    if (result.status != NewtonResultStatus::Success) return x2;
    float2 bary = result.xi_prime;
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.mappingDistance = float2(length(bary - triHit.barycentrics), length(ops.X(bary) - ops.X(triHit.barycentrics)));
#endif
    // Keep the original strict interior test (triangle edges are excluded).
    if (!(bary.x > 0.f && bary.y > 0.f && bary.x + bary.y < 1.f)) return x2;

    VertexData tracedVertex;
    HitInfo hit = traceShiftEndpoint(x3, true, ops.X(bary), tol, tracedVertex);
    if (!hit.isValid()) return x2;
    TriangleHit traced = hit.getTriangleHit();
    if (traced.instanceID.index != triHit.instanceID.index || traced.primitiveIndex != triHit.primitiveIndex) return x2;

    jacobian = result.detJ;
    triHit.barycentrics = bary;
    shiftedVertex = gScene.getVertexData(triHit);
    return HitInfo(triHit);
}

HitInfo shiftRayTrace(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    VertexData v2, // x2's vertex data
    ShadingData x3, // fixed next vertex (surface or point light)
    ShiftSource source,
    ShiftLengthCondition condition,
    float2 a_const,
    out float jacobian,
    out VertexData shiftedVertex, // the returned hit's vertex data
    inout ShiftMappingDebugInfo debuginfo,
    float tol=1e-7
)
{
    shiftedVertex = v2;
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    float3 x = v2.posW;
    float3 n = v2.faceNormalW;

    // Target chart: directions from the target path's y (x3).
    const float3 p2o = x3.computeRayOrigin();
    float3 n2 = x3.getOrientedFaceNormal();
    float3 b2 = perp_stark_onb(n2);
    float3 t2 = cross(b2, n2);
    RayTraceHemisphereChart ops = RayTraceHemisphereChart(p1, p2, p2o, t2, b2, n2);

    // Source chart: directions from the source path's y. It is the target chart unless y moved (re-lit suffix); then
    // xi is the source vertex in the source chart, and the solver traces the target chart's start point X_t(xi).
    bool separateCharts = source.distinctNext;
    const float3 p2os = separateCharts ? source.next.computeRayOrigin() : p2o;
    float3 n2s = separateCharts ? source.next.getOrientedFaceNormal() : n2;
    float3 b2s = separateCharts ? perp_stark_onb(n2s) : b2;
    float3 t2s = separateCharts ? cross(b2s, n2s) : t2;
    RayTraceHemisphereChart sourceOps = RayTraceHemisphereChart(source.p1, source.p2, p2os, t2s, b2s, n2s);
    // x is the first hit from the source's y toward it: the sampled segment x - y_s is unoccluded.
    sourceOps.hit = x2;
    sourceOps.hitT = length(x - p2os);
    if (!separateCharts)
    {
        ops.hit = x2;
        ops.hitT = sourceOps.hitT;
    }

    float3 dir = normalize(x - p2os);
    float3 local = float3(dot(t2s, dir), dot(b2s, dir), dot(n2s, dir));
#if SHIFT_MAPPING_METHOD == SHIFT_MAPPING_RAY_TRACE_CHART
    if (!(local.z > 1e-6f)) { jacobian = 0.f; return x2; }
    ops.useCartesianChart = true;
    sourceOps.useCartesianChart = true;
    float2 xi = local.xy / local.z;
#else
    float2 xi = inverse_sample_hemisphere_preserve_area(local);
#endif

    NewtonResult result = solveShiftNewton(ops, sourceOps, source.distinct, separateCharts, condition, xi,
        getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    recordShiftSolve(result, debuginfo);
    HitInfo new_sample = x2;

    // The gauge system can have several roots when the vertex moves far in a ray chart, and the reverse solve may then
    // converge to another one, so the shift is not its own inverse there. |xi' - xi| is the same for the reverse shift
    // (it compares the raw coordinates of the two charts), so the rejection is symmetric. It removes most such pairs,
    // with no guarantee that every accepted shift returns.
    if (gRayChartMaxDisplacement > 0.f && length(result.xi_prime - xi) > gRayChartMaxDisplacement)
        result.status = NewtonResultStatus::NoConverge;
    if(result.status == NewtonResultStatus::Success && ops.hit.isValid()){
        new_sample = ops.hit;
        VertexData vnew = gScene.getVertexData(new_sample.getTriangleHit());
        shiftedVertex = vnew;
#if DEBUG_NEWTON_ITERATIONS
        debuginfo.mappingDistance = float2(length(result.xi_prime - xi), length(vnew.posW - x));
#endif

        // Area densities: each point in its own chart (x from the source's y, x' from the target's y).
        float L0 = length(p2os - x);
        float L = length(p2o - vnew.posW);
        float3 d0 = normalize(p2os - x);
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
