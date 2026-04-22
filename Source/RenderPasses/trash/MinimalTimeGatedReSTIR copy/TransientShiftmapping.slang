import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
// import Scene.Raytracing;
// import Scene.Intersection;
import Utils.Math.MathHelpers;
import LocalTangentSurface;
import NewtonSolver;
import Scene.RaytracingInline;
import LoadShadingData;
import PathTraceHemisphere;

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

// #define SHIFTMAP_METHOD
#define SHIFTMAP_NO 0
#define SHIFTMAP_LOCAL_TANGENT_SURFACE 1
#define SHFITMAP_RAY_TRACE_HEMISPHERE 2

cbuffer Shiftmap_CB
{
    float2 gGaugeAxis;
    uint gShiftMappingMethod;
}

struct LightSample
{
    HitInfo hit;
    float2 uv;
    float3 p;
    float3 n;
    
    __init()
    {
        this.uv = float2(0.0);
        this.p = float3(0.0);
        this.n = float3(0.0);
    }

    bool isValid(){
        return !(n.x == 0 && n.y == 0 && n.z == 0);
    }
};

struct ShiftMapDebugInfo
{
    float3 temp;
}


LightSample transient_shift_mapping(
    ShadingData x1, // primary hit
    LightSample x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol
)
{
    // jacobian = 1.0;
    // return x2;

    // not valid light sample
    if(all(x2.p == 0.0)){
        jacobian = 0.0;
        return x2;
    }
    // no need for transient shift map!
    if(dt == 0.0){
        jacobian = 1.0;
        return x2;
    }
    switch(gShiftMappingMethod){
        case SHIFTMAP_NO: return transient_shift_mapping_no(x1, x2, x3, dt, jacobian, debuginfo, tol);
        case SHIFTMAP_LOCAL_TANGENT_SURFACE: return transient_shift_mapping_local_tangent_surface(x1, x2, x3, dt, jacobian, debuginfo, tol);
        case SHFITMAP_RAY_TRACE_HEMISPHERE: return transient_shift_mapping_path_trace_shadowmap(x1, x2, x3, dt, jacobian, debuginfo, tol);
    }
    return x2;
}

LightSample transient_shift_mapping_no(
    ShadingData x1, // primary hit
    LightSample x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    jacobian = 1.0;
    return x2;
}


LightSample transient_shift_mapping_local_tangent_surface(
    ShadingData x1, // primary hit
    LightSample x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    float3 x = x2.p;
    float3 n = x2.n;

    float3 bitangent = perp_stark_onb(n);
    float3 tangent = cross(bitangent, n);

    LocalPlaneOps ops = LocalPlaneOps(p1, p2, x, tangent, bitangent);
    float2 eta0 = float2(0, 0);
    float2 a_const = gGaugeAxis;
    NewtonResult result = solve_eta_prime_newton_det(ops, eta0, dt, GaugeMode::CONSTANT_A, a_const, 15, tol);
    float3 x_prime = ops.X(result.eta_prime);

    LightSample new_sample = x2;
    if(result.status == NewtonResultStatus::SUCCESS){   
        float3 dir = normalize(x_prime - p2);

        Ray ray = Ray(x3.computeRayOrigin(), dir, 0.0f, FLT_MAX);
        SceneRayQuery<0> sceneRayQuery;
        float hitT;
        HitInfo hit = sceneRayQuery.traceRay(ray, hitT);

        if(hit.isValid()){
            ShadingData sd = loadShadingData(hit, p2, dir);

            if(length(sd.posW - x_prime) < 1e-3 
                && dot(sd.getOrientedFaceNormal(), n) > 0.999
            )
            {
                Ray visibilityRay = Ray(x1.computeRayOrigin(), 
                    normalize(x_prime - x1.posW), 0.0f, length(x_prime - x1.posW) - 0.001f);
                
                SceneRayQuery<0> sceneRayQuery;
                bool V= sceneRayQuery.traceVisibilityRay(visibilityRay);
                
                if(V){
                    new_sample.p = x_prime;
                    new_sample.hit = hit;
                    jacobian = result.detJ;
                    return new_sample;
                }
            }
        }
    }
    jacobian = 0;
    return new_sample;
}

LightSample transient_shift_mapping_path_trace_shadowmap(
    ShadingData x1, // primary hit
    LightSample x2, // second hit
    ShadingData x3, // laser hit
    float dt,
    out float jacobian,
    inout ShiftMapDebugInfo debuginfo,
    float tol=1e-7
)
{
    const float3 p1 = x1.posW;
    const float3 p2 = x3.posW;
    const float3 p2o = x3.computeRayOrigin();
    float3 x = x2.p;
    float3 n = x2.n;
    float2 eta = x2.uv;
    float3 n2 = x3.getOrientedFaceNormal();
    
    float3 b2 = perp_stark_onb(n2);
    float3 t2 = cross(b2, n2);
    PathTraceHemisphereOps ops = PathTraceHemisphereOps(p1, p2, p2o, t2, b2, n2);
    ops.hit = x2.hit;
    ops.hitT = length(x2.p - p2);

    float2 a_const = gGaugeAxis;
    NewtonResult result = solve_eta_prime_newton_det(ops, eta, dt, GaugeMode::CONSTANT_A, a_const, 15, tol);
    LightSample new_sample = x2;

    if(result.status == NewtonResultStatus::SUCCESS && ops.hit.isValid()){
        new_sample.uv = result.eta_prime;
        new_sample.hit = ops.hit;
        float3 dir = ops.to_world(ops.dir_local(result.eta_prime.x, result.eta_prime.y));
        ShadingData sd = loadShadingData(ops.hit, p2, dir);

        new_sample.p = sd.posW;
        new_sample.n = sd.getOrientedFaceNormal();

        float L0 = length(p2 - x);
        float L = length(p2 - new_sample.p);
        float3 d0 = normalize(p2 - x);
        float3 d = normalize(p2 - new_sample.p);

        float G = abs(dot(n, d0)) / (L0 * L0);
        float G2 = abs(dot(n, d)) / (L * L);
        if(G == 0 || G2 == 0){
            jacobian = 0;
        } else {
            jacobian = result.detJ * G / G2;
        }

        Ray visibilityRay = Ray(x1.posW, 
            normalize(new_sample.p - x1.posW), 1e-3f, length(new_sample.p - x1.posW) - 0.001f);
        
        SceneRayQuery<0> sceneRayQuery;
        bool V= sceneRayQuery.traceVisibilityRay(visibilityRay);

        if(!V){
           jacobian = 0;
        }
        return new_sample;
    }
    jacobian = 0;
    return new_sample;
}