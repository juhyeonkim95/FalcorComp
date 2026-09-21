// All surface charts use the source/target solver and consume result.detJ directly.
import TransientShiftmapping;
import NewtonSolver;
import SurfaceOps.SurfaceOpsInterface;
import Scene.RaytracingInline;
import LoadShadingData;
import Utils.Math.MathHelpers;
import Utils.Transient.TransientUtils;
import SurfaceOps.LocalTangentSurface;
import SurfaceOps.BarycentricTriSurface;
import SurfaceOps.RayTraceHemisphere;
import SurfaceOps.CartesianRayChart;
import Utils.Sampling.SampleGenerator;
#include "Utils/Math/MathConstants.slangh"

#define SHIFTMAP_NO 0
#define SHIFTMAP_LOCAL_TANGENT_SURFACE 1
#define SHIFTMAP_BARYCENTRIC_SURFACE 2
#define SHFITMAP_RAY_TRACE_HEMISPHERE 3
#define SHFITMAP_AREA_ADAPTIVE 4
#define SHIFTMAP_RAY_TRACE_CHART 5

struct PathLengthShiftContext
{
    ShadingData sourceA;
    ShadingData targetA;
    HitInfo xHit;
    ShadingData y;
    bool yIsSurface;
    float offset;
    float K;
    float2 axis;
    float tol;
};

void record_path_length_solve(NewtonResult result, inout ShiftMapDebugInfo debugInfo)
{
    debugInfo.iters = result.iters;
    debugInfo.status = uint(result.status);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
}

HitInfo path_length_aware_no(PathLengthShiftContext c, out float jacobian, inout ShiftMapDebugInfo debugInfo)
{
    jacobian = 1.f;
    debugInfo.status = uint(NewtonResultStatus::SUCCESS);
    return c.xHit;
}

HitInfo path_length_aware_local_tangent_surface(PathLengthShiftContext c, out float jacobian, inout ShiftMapDebugInfo debugInfo)
{
    ShadingData sourceA = c.sourceA, targetA = c.targetA, y = c.y;
    HitInfo xHit = c.xHit;
    bool yIsSurface = c.yIsSurface;
    float offset = c.offset, K = c.K, tol = c.tol;
    float2 axis = c.axis;
    VertexData vertex = gScene.getVertexData(xHit.getTriangleHit());
    float3 x = vertex.posW;
    jacobian = 0.f;
    NewtonResult result;
    HitInfo mappedHit = xHit;
    float areaConversion = 1.f;
    float3 n = vertex.faceNormalW;
    float3 b = perp_stark_onb(n);
    float3 t = cross(b, n);
    LocalPlaneOps ops = LocalPlaneOps(sourceA.posW, targetA.posW, y.posW, x, t, b);
    float sourceLength = length(sourceA.posW - x) + length(x - y.posW);
    float lengthOffset = (K - 1.f) * sourceLength + offset;
    result = solve_xi_prime_newton_det(ops, float2(0.f), lengthOffset,
        getShiftGaugeMode(), axis, gNewtonMaxIteration, tol);
    record_path_length_solve(result, debugInfo);
    if (result.status != NewtonResultStatus::SUCCESS) return xHit;
    float3 desired = ops.X(result.xi_prime);
    mappedHit = trace_shift_endpoint(y, yIsSurface, desired, tol);
    if (!mappedHit.isValid()) return xHit;
    VertexData mapped = gScene.getVertexData(mappedHit.getTriangleHit());
    // A tangent-plane determinant is an area determinant only on this plane.
    if (dot(mapped.faceNormalW, n) < 0.999999f || abs(dot(mapped.posW - x, n)) > tol) return xHit;
    float J = K * result.detJ * areaConversion;
    if (!(J > 0.f) || !isfinite(J)) return xHit;
    jacobian = J;
    return mappedHit;
}

HitInfo path_length_aware_barycentric_surface(PathLengthShiftContext c, out float jacobian, inout ShiftMapDebugInfo debugInfo)
{
    ShadingData sourceA = c.sourceA, targetA = c.targetA, y = c.y;
    HitInfo xHit = c.xHit;
    bool yIsSurface = c.yIsSurface;
    float offset = c.offset, K = c.K, tol = c.tol;
    float2 axis = c.axis;
    VertexData vertex = gScene.getVertexData(xHit.getTriangleHit());
    float3 x = vertex.posW;
    jacobian = 0.f;
    NewtonResult result;
    HitInfo mappedHit = xHit;
    float areaConversion = 1.f;
    TriangleHit tri = xHit.getTriangleHit();
    float3 positions[3];
    gScene.getVertexPositionsW(tri.instanceID, tri.primitiveIndex, positions);
    float scale = length(positions[1] - positions[0]) + length(positions[2] - positions[0]);
    if (!(scale > 1e-8f)) return xHit;
    BarycentricTriOps ops = BarycentricTriOps(sourceA.posW, targetA.posW, y.posW, positions[0], positions[1], positions[2]);
    float sourceLength = length(sourceA.posW - x) + length(x - y.posW);
    float lengthOffset = (K - 1.f) * sourceLength + offset;
    result = solve_xi_prime_newton_det(ops, tri.barycentrics, lengthOffset,
        getShiftGaugeMode(), axis, gNewtonMaxIteration, tol);
    record_path_length_solve(result, debugInfo);
    if (result.status != NewtonResultStatus::SUCCESS) return xHit;
    float2 v = result.xi_prime;
    if (any(v < float2(0.f)) || v.x + v.y > 1.f) return xHit;
    mappedHit = trace_shift_endpoint(y, yIsSurface, ops.X(v), tol);
    if (!mappedHit.isValid()) return xHit;
    TriangleHit traced = mappedHit.getTriangleHit();
    if (traced.instanceID.index != tri.instanceID.index || traced.primitiveIndex != tri.primitiveIndex) return xHit;
    // Return the solved point on the original triangle, whose area factor cancels.
    tri.barycentrics = v;
    mappedHit = HitInfo(tri);
    float J = K * result.detJ * areaConversion;
    if (!(J > 0.f) || !isfinite(J)) return xHit;
    jacobian = J;
    return mappedHit;
}

HitInfo path_length_aware_path_trace_shadowmap(PathLengthShiftContext c, out float jacobian, inout ShiftMapDebugInfo debugInfo)
{
    ShadingData sourceA = c.sourceA, targetA = c.targetA, y = c.y;
    HitInfo xHit = c.xHit;
    bool yIsSurface = c.yIsSurface;
    float offset = c.offset, K = c.K, tol = c.tol;
    float2 axis = c.axis;
    VertexData vertex = gScene.getVertexData(xHit.getTriangleHit());
    float3 x = vertex.posW;
    jacobian = 0.f;
    NewtonResult result;
    HitInfo mappedHit = xHit;
    float areaConversion = 1.f;
    // Both source and target share this offset-origin directional chart.
    float3 origin = shift_ray_origin(y, yIsSurface, x);
    float3 d = x - origin;
    float radius = length(d);
    if (!(radius > 1e-8f)) return xHit;
    d /= radius;
    float3 n = y.getOrientedFaceNormal();
    float3 b = perp_stark_onb(n);
    float3 t = cross(b, n);
    float3 local = float3(dot(t, d), dot(b, d), dot(n, d));
    if (!(local.z > 1e-6f)) return xHit;
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    float2 u = local.xy / local.z;
    if (!CartesianRayChart::isValid(u)) return xHit;
#else
    float2 u = inverse_sample_hemisphere_preserve_area(local);
    if (u.x >= 1.f - 1e-6f) return xHit;
#endif
    float cosine = abs(dot(vertex.faceNormalW, d));
    if (!(cosine > 1e-6f)) return xHit;
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    float directionScale = rsqrt(1.f + dot(u, u));
#else
    float directionScale = max(rsqrt(1.f - u.x * u.x), M_2PI);
#endif
    float chartScale = radius * (1.f + 1.f / cosine) * directionScale;
    RayTraceHemisphereOps ops = RayTraceHemisphereOps(sourceA.posW, targetA.posW, y.posW, origin, t, b, n);
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    ops.useCartesianChart = true;
#endif
    // Require the initial directional chart to recover the original point.
    ops.initializeSource(u);
    if (!ops.hit.isValid()) return xHit;
    if (ops.hit.getType() != HitType::Triangle) return xHit;
    if (length(gScene.getVertexData(ops.hit.getTriangleHit()).posW - x) > 4.f * tol) return xHit;
    float sourceLength = length(sourceA.posW - x) + length(x - y.posW);
    float lengthOffset = (K - 1.f) * sourceLength + offset;
    result = solve_xi_prime_newton_det(ops, u, lengthOffset,
        getShiftGaugeMode(), axis, gNewtonMaxIteration, tol);
    record_path_length_solve(result, debugInfo);
    if (result.status != NewtonResultStatus::SUCCESS || !ops.hit.isValid()) return xHit;
    if (ops.hit.getType() != HitType::Triangle) return xHit;
    mappedHit = ops.hit;
    VertexData mapped = gScene.getVertexData(mappedHit.getTriangleHit());
    float3 mappedRay = mapped.posW - origin;
    float mappedRadius = length(mappedRay);
    if (!(mappedRadius > 1e-8f)) return xHit;
    float mappedCosine = abs(dot(mapped.faceNormalW, mappedRay / mappedRadius));
    if (!(mappedCosine > 1e-6f)) return xHit;
    // dOmega = G dA. The polar chart's constant density cancels; Cartesian
    // slopes need sigma(v)/sigma(u), sigma = (1+u^2+v^2)^(-3/2).
    // Both G's use the offset chart origin, not the physical endpoint y.
    float G0 = cosine / (radius * radius);
    float G1 = mappedCosine / (mappedRadius * mappedRadius);
    areaConversion = G0 / G1;
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    areaConversion *= CartesianRayChart::solidAngleDensity(result.xi_prime) / CartesianRayChart::solidAngleDensity(u);
#endif
    float J = K * result.detJ * areaConversion;
    if (!(J > 0.f) || !isfinite(J)) return xHit;
    jacobian = J;
    return mappedHit;
}

HitInfo path_length_aware_adaptive(PathLengthShiftContext c, out float jacobian, inout ShiftMapDebugInfo debugInfo)
{
    const float areaThreshold = .1f;
    TriangleHit tri = c.xHit.getTriangleHit();
    bool usePlane = gScene.getFaceAreaW(tri.instanceID, tri.primitiveIndex) > areaThreshold;
    HitInfo mapped;
    if (usePlane) mapped = path_length_aware_local_tangent_surface(c, jacobian, debugInfo);
    else mapped = path_length_aware_path_trace_shadowmap(c, jacobian, debugInfo);
    if (!(jacobian > 0.f)) return c.xHit;
    TriangleHit mappedTri = mapped.getTriangleHit();
    bool mappedUsesPlane = gScene.getFaceAreaW(mappedTri.instanceID, mappedTri.primitiveIndex) > areaThreshold;
    if (mappedUsesPlane != usePlane) { jacobian = 0.f; return c.xHit; }
    return mapped;
}

// Spelling of the public entry point follows the requested API.
HitInfo path_lentgh_aware_shift_mapping(
    ShadingData sourceA, float sourcePrefix, ShadingData targetA, float targetPrefix,
    HitInfo xHit, ShadingData y, bool yIsSurface, float suffixLength,
    float sourceTime, float targetTime, float K, uint seed,
    out float jacobian, inout ShiftMapDebugInfo debugInfo, inout SampleGenerator sg)
{
    jacobian = 0.f;
    debugInfo.status = uint(NewtonResultStatus::NO_CONVERGE);
    debugInfo.iters = 0;
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
#endif
    if (!xHit.isValid()) return xHit;
    if (xHit.getType() != HitType::Triangle) return xHit;
    if (!(K > 0.f) || !isfinite(K)) return xHit;
    float3 x = gScene.getVertexData(xHit.getTriangleHit()).posW;
    float sourceLength = sourcePrefix + length(sourceA.posW - x) + length(x - y.posW) + suffixLength;
    float targetLength = targetPrefix + length(targetA.posW - x) + length(x - y.posW) + suffixLength;
    float dt = K * (sourceLength - sourceTime) + targetTime - targetLength;
    PathLengthShiftContext c;
    c.sourceA = sourceA; c.targetA = targetA; c.xHit = xHit;
    c.y = y; c.yIsSurface = yIsSurface; c.K = K;
    // evalSource/evalTarget contain only a -> x -> y. This offset accounts
    // for the remaining path and gate centers. At K=1 it is
    // sourcePrefix - targetPrefix + targetTime - sourceTime, not generally zero.
    c.offset = (sourcePrefix - targetPrefix) + (targetTime - sourceTime)
        + (K - 1.f) * (sourcePrefix + suffixLength - sourceTime);
    c.tol = max(2e-7f * max(1.f, abs(sourceLength)),
        max(gNewtonRelativeTolerance, 0.f) * min(abs(dt), max(time_gate_window, 0.f)));
    c.axis = gGaugeAxis;
    if (all(c.axis == float2(0.f)))
    {
        SampleGenerator axisRng = SampleGenerator(seed);
        float phi = M_2PI * sampleNext1D(axisRng);
        c.axis = float2(cos(phi), sin(phi));
    }
    // Only a truly identical source/target mapping has an identity Jacobian.
    if (K == 1.f && all(sourceA.posW == targetA.posW) &&
        sourcePrefix == targetPrefix && sourceTime == targetTime)
        return path_length_aware_no(c, jacobian, debugInfo);
#if SHIFT_MAPPING_METHOD == SHIFTMAP_NO
    return path_length_aware_no(c, jacobian, debugInfo);
#elif SHIFT_MAPPING_METHOD == SHIFTMAP_LOCAL_TANGENT_SURFACE
    return path_length_aware_local_tangent_surface(c, jacobian, debugInfo);
#elif SHIFT_MAPPING_METHOD == SHIFTMAP_BARYCENTRIC_SURFACE
    return path_length_aware_barycentric_surface(c, jacobian, debugInfo);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_RAY_TRACE_HEMISPHERE || SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    return path_length_aware_path_trace_shadowmap(c, jacobian, debugInfo);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    return path_length_aware_adaptive(c, jacobian, debugInfo);
#else
    return xHit;
#endif
}
