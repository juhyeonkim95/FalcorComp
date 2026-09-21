import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
// import Scene.Raytracing;
// import Scene.Intersection;
import Utils.Math.MathHelpers;
import Scene.RaytracingInline;
import LoadShadingData;
// import RayTraceHemisphere;
import SurfaceOps.LocalTangentSurface;
import SurfaceOps.SurfaceOpsInterface;
import SurfaceOps.BarycentricTriSurface;
import SurfaceOps.RayTraceHemisphere;
import SurfaceOps.CartesianRayChart;

import NewtonSolver;
import Utils.Transient.Ellipsoid;
import Utils.Transient.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;


#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

// #define SHIFTMAP_METHOD
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
    // Reverse validation and backtracking trials are not separate attempts/steps.
    uint4 newtonStats;
#endif
}


HitInfo transient_shift_mapping(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol,
    inout SampleGenerator sg
)
{
    // not valid light sample
    if(!x2.isValid()){
        jacobian = 0.0;
        return x2;
    }
    // no need for transient shift map!
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
    return transient_shift_mapping_no(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFTMAP_LOCAL_TANGENT_SURFACE
    return transient_shift_mapping_local_tangent_surface(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHIFTMAP_BARYCENTRIC_SURFACE
    return transient_shift_mapping_barycentric_surface(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_RAY_TRACE_HEMISPHERE || SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
    return transient_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    return transient_shift_mapping_adaptive(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#endif
    jacobian = 1.0;
    return x2;
}

// Preserve the existing local-plane inverse-branch check. Other surface modes
// use the source/target equations directly; they do not add a reverse solve.
NewtonResult solve_static_surface<SurfaceOps : ISurfaceOps>(
    inout SurfaceOps source, inout SurfaceOps target, float2 u,
    float offset, float K, float2 axis, float tol, float coordinateTol
#if DEBUG_NEWTON_ITERATIONS
    , inout ShiftMapDebugInfo debugInfo
#endif
)
{
    NewtonResult result = solve_paired_shift(source, target, u, offset, K,
        getShiftGaugeMode(), axis, gNewtonMaxIteration, tol, coordinateTol);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
    if (result.status != NewtonResultStatus::SUCCESS) return result;
    // The start-gradient gauge is intentionally asymmetric, so skip the inverse check.
    if (getShiftGaugeMode() == GaugeMode::ORTHO_GRAD_START) return result;
    NewtonResult reverse = solve_paired_shift(target, source, result.xi_prime, -offset / K, 1.f / K,
        getShiftGaugeMode(), axis, gNewtonMaxIteration, tol / K, coordinateTol);
    if (reverse.status != NewtonResultStatus::SUCCESS ||
        length(reverse.xi_prime - u) > 8.f * coordinateTol)
    {
        result.status = NewtonResultStatus::NO_CONVERGE;
        result.detJ = 0.f;
    }
    // Ray-traced Ops are stateful: leave the accepted destination in target.hit.
    target.update(result.xi_prime);
    return result;
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

// Static spatial mapping: L_target(v) = K * L_source(u) + offset.
// For ordinary spatial reuse K=1. No destination-only constant-dt derivative.
HitInfo spatial_shift_mapping(
    ShadingData sourceA, float sourcePrefix, ShadingData targetA, float targetPrefix,
    HitInfo xHit, ShadingData y, bool yIsSurface, float suffixLength,
    float sourceTime, float targetTime, float K, uint seed,
    out float jacobian, inout ShiftMapDebugInfo debugInfo, inout SampleGenerator sg)
{
    jacobian = 0.f;
    debugInfo.status = uint(NewtonResultStatus::NO_CONVERGE);
    debugInfo.iters = 0;
    if (!xHit.isValid()) return xHit;
    if (xHit.getType() != HitType::Triangle) return xHit;
#if SHIFT_MAPPING_METHOD == SHIFTMAP_NO
    // Identity on the surface, independent of any requested length correction.
    jacobian = 1.f;
    debugInfo.status = uint(NewtonResultStatus::SUCCESS);
    return xHit;
#else
    if (!(K > 0.f) || !isfinite(K)) return xHit;
    // Exact self reuse is the identity even at a stationary length gradient.
    // A merely zero dt with DIFFERENT source/target foci is not this case.
    if (K == 1.f && all(sourceA.posW == targetA.posW) &&
        sourcePrefix == targetPrefix && sourceTime == targetTime)
    {
        jacobian = 1.f;
        debugInfo.status = uint(NewtonResultStatus::SUCCESS);
        return xHit;
    }
    VertexData vertex = gScene.getVertexData(xHit.getTriangleHit());
    float3 x = vertex.posW;
    float sourceLength = sourcePrefix + length(sourceA.posW - x) + length(x - y.posW) + suffixLength;
    float targetLength = targetPrefix + length(targetA.posW - x) + length(x - y.posW) + suffixLength;
    float offset = K * (sourcePrefix + suffixLength - sourceTime)
                 + targetTime - targetPrefix - suffixLength;
    float dt = K * (sourceLength - sourceTime) + targetTime - targetLength;
    // Relative to the correction, bounded by the gate width; retain a float
    // precision floor in world units. The UI tolerance now actually participates.
    float tol = max(2e-7f * max(1.f, abs(sourceLength)),
        max(gNewtonRelativeTolerance, 0.f) * min(abs(dt), max(time_gate_window, 0.f)));
    float2 axis = gGaugeAxis;
    if (all(axis == float2(0.f)))
    {
        SampleGenerator axisRng = SampleGenerator(seed);
        float phi = M_2PI * sampleNext1D(axisRng);
        axis = float2(cos(phi), sin(phi));
    }
#if SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    // Adaptive mode alone needs a per-triangle runtime choice.
    const float areaThreshold = 0.1f;
    TriangleHit originalTri = xHit.getTriangleHit();
    bool useLargeTriangle = gScene.getFaceAreaW(originalTri.instanceID, originalTri.primitiveIndex) > areaThreshold;
#endif
    NewtonResult result;
    HitInfo mappedHit = xHit;
    float areaConversion = 1.f;
#if SHIFT_MAPPING_METHOD == SHIFTMAP_LOCAL_TANGENT_SURFACE || SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
#if SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    if (useLargeTriangle)
#endif
    {
        float3 n = vertex.faceNormalW;
        float3 b = perp_stark_onb(n);
        float3 t = cross(b, n);
        LocalPlaneOps source = LocalPlaneOps(sourceA.posW, y.posW, x, t, b);
        LocalPlaneOps target = LocalPlaneOps(targetA.posW, y.posW, x, t, b);
        result = solve_static_surface(source, target, float2(0.f), offset, K, axis, tol, tol
#if DEBUG_NEWTON_ITERATIONS
            , debugInfo
#endif
        );
        debugInfo.iters = result.iters;
        debugInfo.status = uint(result.status);
        if (result.status != NewtonResultStatus::SUCCESS) return xHit;
        float3 desired = target.X(result.xi_prime);
        mappedHit = trace_shift_endpoint(y, yIsSurface, desired, tol);
        if (!mappedHit.isValid()) return xHit;
        VertexData mapped = gScene.getVertexData(mappedHit.getTriangleHit());
        // A tangent-plane determinant is an area determinant only on this plane.
        if (dot(mapped.faceNormalW, n) < 0.999999f || abs(dot(mapped.posW - x, n)) > tol) return xHit;
    }
#endif
#if SHIFT_MAPPING_METHOD == SHIFTMAP_BARYCENTRIC_SURFACE
    {
        TriangleHit tri = xHit.getTriangleHit();
        float3 positions[3];
        gScene.getVertexPositionsW(tri.instanceID, tri.primitiveIndex, positions);
        float scale = length(positions[1] - positions[0]) + length(positions[2] - positions[0]);
        if (!(scale > 1e-8f)) return xHit;
        BarycentricTriOps source = BarycentricTriOps(sourceA.posW, y.posW, positions[0], positions[1], positions[2]);
        BarycentricTriOps target = BarycentricTriOps(targetA.posW, y.posW, positions[0], positions[1], positions[2]);
        result = solve_paired_shift(source, target, tri.barycentrics, offset, K,
            getShiftGaugeMode(), axis, gNewtonMaxIteration, tol, tol / scale);
#if DEBUG_NEWTON_ITERATIONS
        debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
        debugInfo.iters = result.iters;
        debugInfo.status = uint(result.status);
        if (result.status != NewtonResultStatus::SUCCESS) return xHit;
        float2 v = result.xi_prime;
        if (any(v < float2(0.f)) || v.x + v.y > 1.f) return xHit;
        mappedHit = trace_shift_endpoint(y, yIsSurface, target.X(v), tol);
        if (!mappedHit.isValid()) return xHit;
        TriangleHit traced = mappedHit.getTriangleHit();
        if (traced.instanceID.index != tri.instanceID.index || traced.primitiveIndex != tri.primitiveIndex) return xHit;
        // Return the solved point on the original triangle, whose area factor cancels.
        tri.barycentrics = v;
        mappedHit = HitInfo(tri);
    }
#elif SHIFT_MAPPING_METHOD == SHFITMAP_RAY_TRACE_HEMISPHERE || SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART || SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
#if SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    else
#endif
    {
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
        RayTraceHemisphereOps source = RayTraceHemisphereOps(sourceA.posW, y.posW, origin, t, b, n);
        RayTraceHemisphereOps target = RayTraceHemisphereOps(targetA.posW, y.posW, origin, t, b, n);
#if SHIFT_MAPPING_METHOD == SHIFTMAP_RAY_TRACE_CHART
        source.useCartesianChart = true;
        target.useCartesianChart = true;
#endif
        // Require the initial directional chart to recover the original point.
        source.update(u);
        if (!source.hit.isValid()) return xHit;
        if (source.hit.getType() != HitType::Triangle) return xHit;
        if (length(gScene.getVertexData(source.hit.getTriangleHit()).posW - x) > 4.f * tol) return xHit;
        result = solve_paired_shift(source, target, u, offset, K,
            getShiftGaugeMode(), axis, gNewtonMaxIteration, tol, tol / chartScale);
#if DEBUG_NEWTON_ITERATIONS
        debugInfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
        debugInfo.iters = result.iters;
        debugInfo.status = uint(result.status);
        if (result.status != NewtonResultStatus::SUCCESS || !target.hit.isValid()) return xHit;
        if (target.hit.getType() != HitType::Triangle) return xHit;
        mappedHit = target.hit;
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
    }
#elif SHIFT_MAPPING_METHOD != SHIFTMAP_LOCAL_TANGENT_SURFACE
    return xHit;
#endif
#if SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    TriangleHit mappedTri = mappedHit.getTriangleHit();
    float mappedArea = gScene.getFaceAreaW(mappedTri.instanceID, mappedTri.primitiveIndex);
    // The reverse must select the same surface operation, including equality.
    if ((mappedArea > areaThreshold) != useLargeTriangle) return xHit;
#endif
    float J = result.detJ * areaConversion;
    if (!(J > 0.f) || !isfinite(J)) return xHit;
    jacobian = J;
    return mappedHit;
#endif
}

HitInfo transient_shift_mapping_adaptive(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    TriangleHit triHit = x2.getTriangleHit();
    float faceAreaW = gScene.getFaceAreaW(triHit.instanceID, triHit.primitiveIndex);
    float areaThreshold = 0.1f;//time_gate_window * time_gate_window * 100.0;

    if(faceAreaW > areaThreshold){
        HitInfo hit =  transient_shift_mapping_local_tangent_surface(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
        if (!(jacobian > 0.f) || !hit.isValid()) { jacobian = 0.f; return x2; }
        if (hit.getType() != HitType::Triangle) { jacobian = 0.f; return x2; }
        TriangleHit triHit2 = hit.getTriangleHit();
        float faceAreaW2 = gScene.getFaceAreaW(triHit2.instanceID, triHit2.primitiveIndex);
        if(faceAreaW2 <= areaThreshold){
            jacobian = 0.0;
            return x2;
        }
        return hit;
    } else {
        HitInfo hit =  transient_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
        if (!(jacobian > 0.f) || !hit.isValid()) { jacobian = 0.f; return x2; }
        if (hit.getType() != HitType::Triangle) { jacobian = 0.f; return x2; }
        TriangleHit triHit2 = hit.getTriangleHit();
        float faceAreaW2 = gScene.getFaceAreaW(triHit2.instanceID, triHit2.primitiveIndex);
        if(faceAreaW2 > areaThreshold){
            jacobian = 0.0;
            return x2;
        }
        return hit;
    }
}

// bool checkVisibility(const float3 p1, const float3 p2)
// {
//     Ray visibilityRay = Ray(p1, normalize(p2 - p1), 0.001f, length(p2 - p1) - 0.001f);
//     SceneRayQuery<0> sceneRayQuery;
//     return sceneRayQuery.traceVisibilityRay(visibilityRay);
// }

// // HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
// // {
// //     Ray ray = Ray(origin, dir, 0.f, FLT_MAX);
// //     SceneRayQuery<0> sceneRayQuery;
// //     return sceneRayQuery.traceRay(ray, hitT);
// // }


HitInfo transient_shift_mapping_ellipsoid(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    inout SampleGenerator sg)
{
    VertexData v2 = gScene.getVertexData(x2.getTriangleHit());
    
    jacobian = 0.0;
    float targetPathLength = length(x1.posW - v2.posW) + length(v2.posW - x3.posW) + dt;
    Ellipsoid E;
    if(!buildEllipsoidFromFoci(
        x1.posW, x3.posW, targetPathLength,
        x1.getOrientedFaceNormal(), x3.getOrientedFaceNormal(), E)){  
        return x2;
    }

    uint triangleIndex;
    float trianglePdf;
    Sphere sph;
    sph.p = v2.posW;
    sph.R = 0.1;
    uint indices[64];
    uint triangleCount = 0;
    emissiveSamplerShiftmap.findAllTrianglesEllipsoid(E, triangleCount, indices);
    if(triangleCount == 0){
        return x2;
    }
    triangleIndex = indices[uint(triangleCount * sampleNext1D(sg))];
    EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);
    // EmissiveTriangle tri;
    // bool success = false;
    // uint tri_iter = 0;
    // while(tri_iter < 10){
    //     tri_iter+=1;
    //     if(!emissiveSamplerShiftmap.sampleTriangleEllipsoidConditional(
    //         E, sph, sg, triangleIndex, trianglePdf)){
    //         continue;
    //     }
    //     tri = gScene.triCollection.getTriangle(triangleIndex);
    //     if(!isTriangleValid(E, tri.posW[0], tri.posW[1], tri.posW[2], tri.normal)){
    //         continue;
    //     }
    //     else{
    //         success = true;
    //         break;
    //     }
    // }
    
    // if(!success){
    //     return x2;
    // }
    SampleResultArea result = sampleOnTriangleEllipsoid(
        E,
        tri.posW[0], tri.posW[1], tri.posW[2],
        sampleNext1D(sg), sampleNext1D(sg));
    
    if(result.ok){
        // new_sample.p = result.p;
        // return new_sample;
        
        // shoot ray to sampled point
        float hitT;
        Ray ray = Ray(x3.computeRayOrigin(), normalize(result.p - x3.posW), 0.f, FLT_MAX);
        SceneRayQuery<0> sceneRayQuery;
        HitInfo hit = sceneRayQuery.traceRay(ray , hitT);
        ShadingData second_sd = loadShadingData(hit, x3.computeRayOrigin(), normalize(result.p - x3.posW));

        // valid point?
        if(hitT > 0 && hit.isValid()
            && abs(dot(second_sd.getOrientedFaceNormal(), tri.normal)) > 0.999 
            && abs(hitT - length(x3.posW - result.p)) < 1e-3){
                jacobian = 1.0;
                return hit;
                // bool V = checkVisibility(x1.computeRayOrigin(), second_sd.posW);
                // if(V){
                //     new_sample.n = second_sd.getOrientedFaceNormal();
                //     new_sample.p = second_sd.posW;
                //     new_sample.hit = hit;

                //     jacobian = 1.0;
                //     return new_sample;
                // }
        }
    }
    return x2;
}

HitInfo transient_shift_mapping_no(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
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

HitInfo transient_shift_mapping_local_tangent_surface(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
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
    float2 eta0 = float2(0, 0);
    // float2 a_const = gGaugeAxis;
    NewtonResult result = solve_xi_prime_newton_det(ops, eta0, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
    float3 x_prime = ops.X(result.xi_prime);
    debuginfo.iters = result.iters;
    debuginfo.status = uint(result.status);
    
    HitInfo new_sample = x2;
    if(result.status == NewtonResultStatus::SUCCESS){   
        HitInfo hit = trace_shift_endpoint(x3, true, x_prime, tol);

        if(hit.isValid()){
            VertexData v = gScene.getVertexData(hit.getTriangleHit());
            if(abs(dot(v.posW - x, n)) <= tol
                && dot(v.faceNormalW, n) > 0.999999f
            )
            {
                jacobian = result.detJ;
                return hit;
            }
        }
    }
    
    jacobian = 0;
    return new_sample;
}


HitInfo transient_shift_mapping_barycentric_surface(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    float2 a_const,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    TriangleHit triHit = x2.getTriangleHit();
    VertexData v2 = gScene.getVertexData(triHit);
    float3 triposW[3];
    gScene.getVertexPositionsW(triHit.instanceID, triHit.primitiveIndex, triposW);
    
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    BarycentricTriOps ops = BarycentricTriOps(p1, p2, triposW[0], triposW[1], triposW[2]);
    NewtonResult result = solve_xi_prime_newton_det(ops, triHit.barycentrics, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
    float3 x_prime = ops.X(result.xi_prime);
    debuginfo.iters = result.iters;
    debuginfo.status = uint(result.status);

    HitInfo new_sample = x2;
    if(result.status == NewtonResultStatus::SUCCESS){
        if(result.xi_prime.x > 0 && result.xi_prime.x < 1 && result.xi_prime.y > 0 && result.xi_prime.y < 1 && 
            (result.xi_prime.x+result.xi_prime.y) > 0 && (result.xi_prime.x+result.xi_prime.y) < 1){
                HitInfo hit = trace_shift_endpoint(x3, true, x_prime, tol);
                if (hit.isValid()) {
                    TriangleHit traced = hit.getTriangleHit();
                    if (traced.instanceID.index != triHit.instanceID.index ||
                        traced.primitiveIndex != triHit.primitiveIndex) { jacobian = 0.f; return x2; }
                    jacobian = result.detJ;
                    triHit.barycentrics = result.xi_prime;
                    return HitInfo(triHit);
                }
            }
    }
    jacobian = 0;
    return new_sample;
}

HitInfo transient_shift_mapping_path_trace_shadowmap(
    ShadingData x1, // primary hit
    HitInfo x2, // second hit
    ShadingData x3, // laser hit
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
    float2 eta = local.xy / local.z;
#else
    float2 eta = inverse_sample_hemisphere_preserve_area(local);
#endif

    NewtonResult result = solve_xi_prime_newton_det(ops, eta, dt, getShiftGaugeMode(), a_const, gNewtonMaxIteration, tol);
#if DEBUG_NEWTON_ITERATIONS
    debuginfo.newtonStats = uint4(result.status == NewtonResultStatus::SUCCESS, 0, 1, result.iters);
#endif
    HitInfo new_sample = x2;
    debuginfo.iters = result.iters;
    debuginfo.status = uint(result.status);

    if(result.status == NewtonResultStatus::SUCCESS && ops.hit.isValid()){
        new_sample = ops.hit;
        VertexData vnew = gScene.getVertexData(new_sample.getTriangleHit());

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
            jacobian *= CartesianRayChart::solidAngleDensity(result.xi_prime) / CartesianRayChart::solidAngleDensity(eta);
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
