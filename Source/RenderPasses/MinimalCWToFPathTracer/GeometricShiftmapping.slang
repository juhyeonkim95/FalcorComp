import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
// import Scene.Raytracing;
// import Scene.Intersection;
import Utils.Math.MathHelpers;
import Scene.RaytracingInline;
// import LoadShadingData;
// import RayTraceHemisphere;
import SurfaceOps.LocalTangentSurface;
import SurfaceOps.BarycentricTriSurface;
// import SurfaceOps.RayTraceHemisphere;

import NewtonSolver;
// import Utils.Transient.Ellipsoid;
// import Utils.Transient.EllipsoidIntersection;
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


struct ShiftMapDebugInfo
{
    int iters;
    uint status;
}


HitInfo transient_shift_mapping(
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
    NewtonResult result = solve_eta_prime_newton_det(ops, eta0, dt, GaugeMode(gGaugeMode), a_const, gNewtonMaxIteration, tol);
    float3 x_prime = ops.X(result.eta_prime);
    debuginfo.iters = result.iters;
    debuginfo.status = uint(result.status);
    
    HitInfo new_sample = x2;
    if(result.status == NewtonResultStatus::SUCCESS){   
        float3 dir = normalize(x_prime - p1);

        Ray ray = Ray(x1.computeRayOrigin(), dir, 0.0f, length(x_prime - x1.posW) + 0.01f);
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