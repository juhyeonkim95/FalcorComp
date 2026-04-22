import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import LoadShadingData;
import Scene.RaytracingInline;
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import LaserLightSampler;
import Rendering.Lights.LightHelpers;



struct Reservoir
{
#if USE_SINGLE_CHANNEL
    float f;
#else
    float3 f;
#endif
    float cachedJacobian;
    float wSum;
    float M;
    float W;
    HitInfo rcVertexHit;
    float rcVertexPostPathLength;
#if USE_SINGLE_CHANNEL
    float rcVertexPostIrradiance;
#else
    float3 rcVertexPostIrradiance;
#endif

    float3 rcVertexWi;
    uint rcVertexBounce;
    uint initRandomSeed;

    [mutating]
    bool update(float3 newf, float weight, float M, inout SampleGenerator sg){
        this.wSum += weight;
        this.M += M;
        if(sampleNext1D(sg) * this.wSum < weight){
            #if USE_SINGLE_CHANNEL
            this.f = luminance(newf);
            #else
            this.f = newf;
            #endif
            return true;
        }
        return false;
    }

    __init()
    {
        this.wSum = 0;
        this.M = 0;
        this.f = 0.0;
        this.W = 0.0;
        this.rcVertexPostPathLength = 0.0;
        this.rcVertexPostIrradiance = 0.0;
        this.rcVertexWi = float3(0.0);
        this.rcVertexBounce = 0;
        this.cachedJacobian = 1.0;
    }
};

Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
{
	Reservoir s = Reservoir();
	s.update(r1.f, luminance(r1.f) * r1.W * r1.M / (r1.M + r2.M), r1.M, sg);
    s.update(r2.f, luminance(r2.f) * r2.W * r2.M / (r1.M + r2.M), r2.M, sg);
    s.M = r1.M + r2.M;
    float pHat = luminance(s.f);
    s.W = (pHat == 0 || s.M == 0) ? 0 : (1 / pHat) * (s.wSum);
    return s;
}


// this shifts curr to other.
void combine_reservoir_with_shiftmapping(
    inout Reservoir dst_reservoir,
    Reservoir curr_reservoir,
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    uint curr_tbin_idx,
    bool is_curr_canonical,
    inout SampleGenerator sg
){
    // no valid sample in reservoir
    if(curr_reservoir.W == 0.0)
    {
        dst_reservoir.M += curr_reservoir.M;
        return;
    }

    // sample cannot be shared with other. (update only for canonical)
    if(curr_reservoir.W > 0 && curr_reservoir.rcVertexBounce == 0){
        if(is_curr_canonical){
            float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);
            float weight = 1.0 * pHat_proxy_curr_as_curr * curr_reservoir.W;
            if(dst_reservoir.update(curr_reservoir.f, weight, curr_reservoir.M, sg)){
                dst_reservoir.rcVertexBounce = 0;
            }
        } else {
            dst_reservoir.M += curr_reservoir.M;
        }
        return;
    }
    
    // (2) curr as other
    // (2-1) reconstruct prefix
    float3 other_prefix_throughput = float3(1.0);
    if(curr_reservoir.rcVertexBounce > 1){
        // reconstructPrefix(
        //     curr_reservoir.rcVertexBounce,
        //     curr_reservoir.initRandomSeed,
        //     other_x1,
        //     other_x1_mi,
        //     other_d01,
        //     other_prefix_throughput
        // );
    }
    VertexData curr_v2 = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
    ShadingData curr_x2 = loadShadingData(curr_reservoir.rcVertexHit, float3(0.0), normalize(curr_v2.posW - other_x1.posW));
    IMaterialInstance curr_x2_mi = gScene.materials.getMaterialInstance(curr_x2, ExplicitLodTextureSampler(0));

    // evaluate updated path throughput
    float3 d12 = curr_x2.posW - other_x1.posW;
    float3 v12 = normalize(d12);
    float3 v23 = -curr_reservoir.rcVertexWi;

    float G12 = max(dot(d12, d12), kMinLightDistSqr);
    float l12 = length(d12);

    float3 f1 = other_x1_mi.eval(other_x1, v12, sg);
    float pdf1 = other_x1_mi.evalPdf(other_x1, v12);

    float3 f2 = curr_x2_mi.eval(curr_x2, v23, sg);
    BSDFProperties aa = other_x1_mi.getProperties(other_x1);

    float3 f_curr_as_other = aa.diffuseReflectionAlbedo * f2 * curr_reservoir.rcVertexPostIrradiance;


    // f_curr_as_other *= other_prefix_throughput;
    // f_curr_as_other = curr_reservoir.f;
    // if(length(f_curr_as_other) < 1e-6){
    //     f_curr_as_other = curr_reservoir.f;
    // }
    
    // check visibility
    Ray visibilityRay = Ray(other_x1.posW, v12, 1e-4, max(l12 - 1e-4, 1e-4));
    SceneRayQuery<0> sceneRayQuery;
    bool V = sceneRayQuery.traceVisibilityRay(visibilityRay);
    f_curr_as_other *= float(V);

    // check path length is still valid
    float pathLength = other_d01 + l12 + curr_reservoir.rcVertexPostPathLength;
    uint pathLengthIdx;
    float pathLengthIdxResidual;
    bool pathLengthIndexValid = false;
    if(getPathLengthIndex(pathLength, pathLengthIdx, pathLengthIdxResidual)){
        if(pathLengthIdx == curr_tbin_idx){
            pathLengthIndexValid = true;
        } 
    }
    // f_curr_as_other *= float(pathLengthIndexValid);

    float pHat_proxy_curr_as_other = luminance(f_curr_as_other);

    float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);
    float M_curr = curr_reservoir.M;
    
    float nom = M_curr * pHat_proxy_curr_as_curr;
    float denom = nom + M_other * pHat_proxy_curr_as_other;
    float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;
    // if(denom < 1e-6 || nom < 1e-6){
    //     mis_weight = 1.0;
    // }

    if(is_curr_canonical){
        float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
        if(dst_reservoir.update(curr_reservoir.f, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
            dst_reservoir.rcVertexWi = curr_reservoir.rcVertexWi;
            dst_reservoir.rcVertexPostIrradiance = curr_reservoir.rcVertexPostIrradiance;
            dst_reservoir.rcVertexPostPathLength = curr_reservoir.rcVertexPostPathLength;
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
        }
    } else {
        float weight = mis_weight * pHat_proxy_curr_as_other * curr_reservoir.W;
        if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
            dst_reservoir.rcVertexWi = curr_reservoir.rcVertexWi;
            dst_reservoir.rcVertexPostIrradiance = curr_reservoir.rcVertexPostIrradiance;
            dst_reservoir.rcVertexPostPathLength = curr_reservoir.rcVertexPostPathLength;
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
        }
    }
}
