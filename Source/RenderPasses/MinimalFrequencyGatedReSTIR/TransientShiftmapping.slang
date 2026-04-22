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
import SurfaceOps.BarycentricTriSurface;
import SurfaceOps.RayTraceHemisphere;

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


cbuffer Shiftmap_CB
{
    float2 gGaugeAxis;
    uint gShiftMappingMethod;
    uint gGaugeMode;
    uint gNewtonMaxIteration;
    float gNewtonRelativeTolerance;
    EmissiveLightSampler emissiveSamplerShiftmap;           ///< Emissive light sampler. Only valid when kUseEmissiveLights == true.
}

float3 getVelocity(HitInfo hit)
{   
    if(!hit.isValid()){
        return float3(0,0,0);
    }
    TriangleHit triHit = hit.getTriangleHit();
    float faceAreaW = gScene.getFaceAreaW(triHit.instanceID, triHit.primitiveIndex);
    //if(faceAreaW < 0.5){
    if(triHit.instanceID.index == 5){
        return float3(0, 0, -10.0);
    } else if(triHit.instanceID.index == 6){
        return float3(0, 0, 10.0);
    }
    else {
        return float3(0, 0, 0);
    }
}

struct ShiftMapDebugInfo
{
    float3 temp;
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
#elif SHIFT_MAPPING_METHOD == SHFITMAP_RAY_TRACE_HEMISPHERE
    return transient_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#elif SHIFT_MAPPING_METHOD == SHFITMAP_AREA_ADAPTIVE
    return transient_shift_mapping_adaptive(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
#endif
    // switch(gShiftMappingMethod){
    //     case SHIFTMAP_NO: 
    //     case SHIFTMAP_LOCAL_TANGENT_SURFACE: return transient_shift_mapping_local_tangent_surface(x1, x2, x3, dt, jacobian, debuginfo, tol);
    //     case SHIFTMAP_BARYCENTRIC_SURFACE: return transient_shift_mapping_barycentric_surface(x1, x2, x3, dt, jacobian, debuginfo, tol);
    //     case SHFITMAP_RAY_TRACE_HEMISPHERE: 
    //     case SHFITMAP_AREA_ADAPTIVE: return transient_shift_mapping_adaptive(x1, x2, x3, dt, jacobian, debuginfo, tol);
    // }

    jacobian = 1.0;
    return x2;
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
        TriangleHit triHit2 = hit.getTriangleHit();
        float faceAreaW2 = gScene.getFaceAreaW(triHit2.instanceID, triHit2.primitiveIndex);
        if(faceAreaW < areaThreshold){
            jacobian = 0.0;
            return x2;
        }
        return hit;
    } else {
        HitInfo hit =  transient_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, a_const, jacobian, debuginfo, tol);
        TriangleHit triHit2 = hit.getTriangleHit();
        float faceAreaW2 = gScene.getFaceAreaW(triHit2.instanceID, triHit2.primitiveIndex);
        if(faceAreaW > areaThreshold){
            jacobian = 0.0;
            return x2;
        }
        return hit;
    }
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
    
    const float3 v1 = x1.velW;
    const float3 v3 = x3.velW;
    const float3 v = getVelocity(x2);

    float3 x = v2.posW;
    float3 n = v2.faceNormalW;

    float3 bitangent = perp_stark_onb(n);
    float3 tangent = cross(bitangent, n);

    LocalPlaneOps ops = LocalPlaneOps(p1, p2, v1, v3, v, x, tangent, bitangent);
    float2 eta0 = float2(0, 0);
    // float2 a_const = gGaugeAxis;
    NewtonResult result = solve_eta_prime_newton_det(ops, eta0, dt, GaugeMode(gGaugeMode), a_const, gNewtonMaxIteration, tol);
    float3 x_prime = ops.X(result.eta_prime);

    HitInfo new_sample = x2;
    if(result.status == NewtonResultStatus::SUCCESS){   
        float3 dir = normalize(x_prime - p2);

        Ray ray = Ray(x3.computeRayOrigin(), dir, 0.0f, length(x_prime - x3.posW) + 0.01f);
        SceneRayQuery<0> sceneRayQuery;
        float hitT;
        HitInfo hit = sceneRayQuery.traceRay(ray, hitT);

        if(hit.isValid()){
            VertexData v = gScene.getVertexData(hit.getTriangleHit());
            if(length(v.posW - x_prime) < 1e-3 
                && dot(v.faceNormalW, n) > 0.999
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
    NewtonResult result = solve_eta_prime_newton_det(ops, triHit.barycentrics, dt, GaugeMode(gGaugeMode), a_const, gNewtonMaxIteration, tol);
    float3 x_prime = ops.X(result.eta_prime);

    HitInfo new_sample = x2;
    if(result.status == NewtonResultStatus::SUCCESS){
        if(result.eta_prime.x > 0 && result.eta_prime.x < 1 && result.eta_prime.y > 0 && result.eta_prime.y < 1 && 
            (result.eta_prime.x+result.eta_prime.y) > 0 && (result.eta_prime.x+result.eta_prime.y) < 1){
                float3 dir = normalize(x_prime - p2);
                Ray visibilityRay = Ray(x3.computeRayOrigin(), normalize(x_prime - p2), 0.0f, length(x_prime - p2) - 0.001f);
                SceneRayQuery<0> sceneRayQuery;
                if(sceneRayQuery.traceVisibilityRay(visibilityRay)){
                    jacobian = result.detJ;
                    triHit.barycentrics = result.eta_prime;
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
    ops.hitT = length(v2.posW - p2);

    float3 dir = normalize(v2.posW - x3.posW);
    float3 local = float3(dot(t2, dir), dot(b2, dir), dot(n2, dir));
    float2 eta = inverse_sample_hemisphere_preserve_area(local);

    NewtonResult result = solve_eta_prime_newton_det(ops, eta, dt, GaugeMode(gGaugeMode), a_const, gNewtonMaxIteration, tol);
    HitInfo new_sample = x2;

    if(result.status == NewtonResultStatus::SUCCESS && ops.hit.isValid()){
        new_sample = ops.hit;
        VertexData vnew = gScene.getVertexData(new_sample.getTriangleHit());

        float L0 = length(p2 - x);
        float L = length(p2 - vnew.posW);
        float3 d0 = normalize(p2 - x);
        float3 d = normalize(p2 - vnew.posW);

        float G = (L0 * L0) < 1e-9 ? 0.0 : abs(dot(n, d0)) / (L0 * L0);
        float G2 = (L * L) < 1e-9 ? 0.0 : abs(dot(vnew.faceNormalW, d)) / (L * L);
        if(G < 1e-9 || G2 < 1e-9){
            jacobian = 0;
        } else {
            jacobian = result.detJ * G / G2;
        }
        if(jacobian < 0.5 || jacobian > 2){
            jacobian = 0.0;
        }
        return new_sample;
    }
    jacobian = 0;
    return new_sample;
}

