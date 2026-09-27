import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.PathLengthNewtonSolver.SurfaceOps.LocalTangentSurface;
import RenderPasses.Shared.Shaders.PathLengthNewtonSolver.SurfaceOps.BarycentricTriSurface;
import RenderPasses.Shared.Shaders.PathLengthNewtonSolver.SurfaceOps.RayTraceHemisphere;
import RenderPasses.Shared.Shaders.PathLengthNewtonSolver.SurfaceOps.CartesianRayChart;

import RenderPasses.Shared.Shaders.PathLengthNewtonSolver.NewtonSolver;
import Rendering.Lights.EmissiveLightSampler;

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

#define SHIFTMAP_NO 0
#define SHIFTMAP_LOCAL_TANGENT_SURFACE 1
#define SHIFTMAP_BARYCENTRIC_SURFACE 2
#define SHFITMAP_RAY_TRACE_HEMISPHERE 3
#define SHFITMAP_AREA_ADAPTIVE 4
#define SHIFTMAP_RAY_TRACE_CHART 5

cbuffer Shiftmap_CB
{
    float2 gGaugeAxis;
    uint gShiftMappingMethod;
    uint gGaugeMode;
    uint gNewtonMaxIteration;
    float gNewtonRelativeTolerance;
    EmissiveLightSampler emissiveSamplerShiftmap;           ///< Emissive light sampler. Only valid when kUseEmissiveLights == true.
}

// The render pass specializes the selected gauge, avoiding runtime gauge
// branches inside every Newton evaluation. Standalone users retain the uniform.
GaugeMode getShiftGaugeMode()
{
#ifdef SHIFT_MAPPING_GAUGE_MODE
    return GaugeMode(SHIFT_MAPPING_GAUGE_MODE);
#else
    return GaugeMode(gGaugeMode);
#endif
}

struct ShiftMapDebugInfo
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
void record_shift_solve(NewtonResult result, inout ShiftMapDebugInfo debugInfo)
{
    debugInfo.iters = result.iters;
    debugInfo.status = uint(result.status);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
}

HitInfo path_length_aware_shift_mapping(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
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

#if SHIFT_MAPPING_METHOD == SHIFTMAP_NO
    return path_length_aware_shift_mapping_no(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFTMAP_LOCAL_TANGENT_SURFACE
    return path_length_aware_shift_mapping_local_tangent_surface(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFTMAP_BARYCENTRIC_SURFACE
    return path_length_aware_shift_mapping_barycentric_surface(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_RAY_TRACE_HEMISPHERE || SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    return path_length_aware_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    return path_length_aware_shift_mapping_adaptive(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#endif
    jacobian = 1.0;
    return x2;
}

float3 shift_ray_origin(ShadingData endpoint, bool isSurface, float3 destination)
{
    if (!isSurface) return endpoint.posW;
    return endpoint.computeRayOrigin(dot(endpoint.getOrientedFaceNormal(), destination - endpoint.posW) >= 0.f);
}

// Recover the surface endpoint using a direction and distance computed from the
// SAME offset origin. There is no fixed world-space endpoint subtraction.
HitInfo trace_shift_endpoint(ShadingData endpoint, bool isSurface, float3 destination, float tol)
{
    float3 origin = shift_ray_origin(endpoint, isSurface, destination);
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

HitInfo path_length_aware_shift_mapping_adaptive(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    const float areaThreshold = 0.01f;
    TriangleHit original = x2.getTriangleHit();
    bool usePlane = gScene.getFaceAreaW(original.instanceID, original.primitiveIndex) > areaThreshold;
    HitInfo hit;
    if (usePlane)
        hit = path_length_aware_shift_mapping_local_tangent_surface(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
    else
        hit = path_length_aware_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);

    if (!(jacobian > 0.f) || !hit.isValid()) { jacobian = 0.f; return x2; }
    if (hit.getType() != HitType::Triangle) { jacobian = 0.f; return x2; }
    TriangleHit shifted = hit.getTriangleHit();
    bool shiftedUsesPlane = gScene.getFaceAreaW(shifted.instanceID, shifted.primitiveIndex) > areaThreshold;
    // Both endpoints must select the same surface operation.
    if (shiftedUsesPlane != usePlane) { jacobian = 0.f; return x2; }
    return hit;
}

HitInfo path_length_aware_shift_mapping_no(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    debuginfo.iters = 0;
    debuginfo.status = 0;
    jacobian = 1.0;
    return x2;
}

HitInfo path_length_aware_shift_mapping_local_tangent_surface(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
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

    LocalPlaneOps ops = LocalPlaneOps(p1, p2, x, tangent, bitangent);
    float2 xi = float2(0, 0);
    NewtonResult result = solve_xi_prime_newton_det(ops, xi, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    record_shift_solve(result, debuginfo);
    jacobian = 0.f;
    if (result.status != NewtonResultStatus::SUCCESS) return x2;

    float3 x_prime = ops.X(result.xi_prime);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.mappingDistance = float2(length(result.xi_prime - xi), length(x_prime - x));
#endif
    HitInfo hit = trace_shift_endpoint(x3, true, x_prime, tol);
    if (!hit.isValid()) return x2;
    VertexData shifted = gScene.getVertexData(hit.getTriangleHit());
    if (!(abs(dot(shifted.posW - x, n)) <= tol && dot(shifted.faceNormalW, n) > 0.999999f)) return x2;

    jacobian = result.detJ;
    return hit;
}

HitInfo path_length_aware_shift_mapping_barycentric_surface(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    TriangleHit triHit = x2.getTriangleHit();
    float3 triposW[3];
    gScene.getVertexPositionsW(triHit.instanceID, triHit.primitiveIndex, triposW);

    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    BarycentricTriOps ops = BarycentricTriOps(p1, p2, triposW[0], triposW[1], triposW[2]);
    NewtonResult result = solve_xi_prime_newton_det(ops, triHit.barycentrics, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    record_shift_solve(result, debuginfo);
    jacobian = 0.f;
    if (result.status != NewtonResultStatus::SUCCESS) return x2;
    float2 bary = result.xi_prime;
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.mappingDistance = float2(length(bary - triHit.barycentrics), length(ops.X(bary) - ops.X(triHit.barycentrics)));
#endif
    // Keep the original strict interior test (triangle edges are excluded).
    if (!(bary.x > 0.f && bary.y > 0.f && bary.x + bary.y < 1.f)) return x2;

    HitInfo hit = trace_shift_endpoint(x3, true, ops.X(bary), tol);
    if (!hit.isValid()) return x2;
    TriangleHit traced = hit.getTriangleHit();
    if (traced.instanceID.index != triHit.instanceID.index || traced.primitiveIndex != triHit.primitiveIndex) return x2;

    jacobian = result.detJ;
    triHit.barycentrics = bary;
    return HitInfo(triHit);
}

HitInfo path_length_aware_shift_mapping_path_trace_shadowmap(
    ShadingData x1, // preceding vertex
    HitInfo x2, // vertex to shift
    ShadingData x3, // fixed next vertex (surface or point light)
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
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

    RayTraceHemisphereOps ops = RayTraceHemisphereOps(p1, p2, p2o, t2, b2, n2);
    ops.hit = x2;
    ops.hitT = length(v2.posW - p2o);

    float3 dir = normalize(v2.posW - p2o);
    float3 local = float3(dot(t2, dir), dot(b2, dir), dot(n2, dir));
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    if (!(local.z > 1e-6f)) { jacobian = 0.f; return x2; }
    ops.useCartesianChart = true;
    float2 xi = local.xy / local.z;
#else
    float2 xi = inverse_sample_hemisphere_preserve_area(local);
#endif

    NewtonResult result = solve_xi_prime_newton_det(ops, xi, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
    record_shift_solve(result, debuginfo);
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
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
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
