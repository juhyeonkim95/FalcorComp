import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import TransientShiftmapping;
import LoadShadingData;
import Scene.RaytracingInline;
#include "Utils/Math/MathConstants.slangh"



struct Reservoir
{
    float3 f;
    float wSum;
    float M;
    float W;

    HitInfo rcVertexHit;
    HitInfo rcNextVertexHit;
    float3 rcNextVertexWi;
    float3 rcNextVertexIrradiance;
    float rcNextVertexPathLength;
    float rcVertexPathLength;
    uint rcVertexBounce;

    uint initRandomSeed;

    // uint rcNextRandomSeed;
    // float2 laseruv;

    [mutating]
    bool update(float3 newf, float weight, float M, inout SampleGenerator sg){
        this.wSum += weight;
        this.M += M;
        if(sampleNext1D(sg) * this.wSum < weight){
            this.f = newf;
            return true;
        }
        return false;
    }
    __init()
    {
        this.wSum = 0;
        this.M = 0;
        this.f = float3(0.0);
        this.W = 0.0;
        this.rcNextVertexWi = float3(1,0,0);
        this.rcNextVertexIrradiance = float3(0.0);
        this.rcNextVertexPathLength = 0.0;
        this.rcVertexBounce = 0;
    }
};

// Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
// {
// 	Reservoir s = Reservoir();
// 	s.update(r1.f, luminance(r1.f) * r1.W * r1.M / (r1.M + r2.M), sg);
//     s.update(r2.f, luminance(r2.f) * r2.W * r2.M / (r1.M + r2.M), sg);
//     s.M = r1.M + r2.M;
//     float pHat = luminance(s.f);
//     s.W = (pHat == 0 || s.M == 0) ? 0 : (1 / pHat) * (s.wSum);
//     return s;
// }


float3 getPHat3(
    const ShadingData sd1,
    const IMaterialInstance mi1,
    const ShadingData sd2,
    const ShadingData sd3,
    const IMaterialInstance mi3,
    const float d01,
    const float d34,
    const float target_dist,
    const float3 irradiance,
    inout SampleGenerator sg
){
    let mi2 = gScene.materials.getMaterialInstance(sd2, ExplicitLodTextureSampler(0));

    const float3 p1 = sd1.posW;
    const float3 p2 = sd2.posW;
    const float3 p3 = sd3.posW;

    const float3 n2 = sd2.getOrientedFaceNormal();

    const float3 l12 = p2 - p1;
    const float3 l32 = p2 - p3;
    const float3 v12 = normalize(l12);
    const float3 v32 = normalize(l32);
    const float d12 = length(p2 - p1);
    const float d32 = length(p2 - p3);
    float3 f1 = mi1.eval(sd1, v12, sg);
    float3 f2 = mi2.eval(sd2, -v32, sg);
    float3 f3 = mi3.eval(sd3, v32, sg);
    float n21 = max(dot(n2, -v12), 0.0);
    if(n21 < 1e-6)
        return float3(0.0);

    float G12 = dot(l12, l12);
    float G23 = dot(l32, l32);
    if(G12 < 1e-9 || G23 < 1e-9)
        return float3(0.0);

    float3 f = f1 * f2 * f3 * n21 / (G12 * G23) * irradiance;
    float distance = d01 + d12 + d32 + d34;
    f *= pathLengthImportance(distance, target_dist);
    return f;
}

bool checkVisibility(const float3 p1, const float3 p2)
{
    Ray visibilityRay = Ray(p1, normalize(p2 - p1), 0.001f, length(p1 - p2) - 0.001f);
    SceneRayQuery<0> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

void reconstructPrefix(
    uint targetBounce,
    uint initRandomSeed,
    inout ShadingData x1,
    inout IMaterialInstance x1_mi,
    inout float d01,
    inout float3 prefixThroughput
)
{
    if (targetBounce <= 1) return;

    HitInfo hit;
    float   hitT;
    BSDFSample bsdfSample;
    SampleGenerator sg_new = SampleGenerator(initRandomSeed);

    for (uint depth = 1; depth < targetBounce; depth++)
    {
        x1_mi.sample(x1, sg_new, bsdfSample, true);

        bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

        // Keep RNG streams aligned with main integrator.
        sampleNext2D(sg_new); // for light sampling
        sampleNext1D(sg_new); // for reservoir update

        prefixThroughput *= bsdfSample.weight;

        Ray ray = Ray(x1.computeRayOrigin(!is_transmission), bsdfSample.wo, 1e-4f, FLT_MAX);
        SceneRayQuery<0> sceneRayQuery;
        hit = sceneRayQuery.traceRay(ray, hitT);
        if (!hit.isValid())
        {
            prefixThroughput = 0.0;
            break;
        }

        d01 += hitT;
        x1 = loadShadingData(hit, ray.origin, ray.dir);
        x1_mi = gScene.materials.getMaterialInstance(x1, ExplicitLodTextureSampler(0.f));
    }
}

void finetune_()
{
    const float K = time_gate_window / time_gate_window_rough;

    if(K < 1)
    {
        float L0 = 
    }

}


// void combine_reservoir_with_shiftmapping(
//     inout Reservoir new_reservoir,
//     Reservoir prev_reservoir,
//     float M_curr,
//     ShadingData curr_x1,
//     IMaterialInstance curr_x1_mi,
//     float curr_d01,
//     const float prev_t,
//     const float curr_t,
//     bool is_curr_canonical,
//     inout SampleGenerator sg
// )
// {
// 	float M_prev = prev_reservoir.M;//min(prev_reservoir.M, 640.0);

    
//     float dt_target = curr_t - prev_t;
//     ShiftMapDebugInfo debugInfo;
    
//     if(prev_reservoir.W > 0){
//         ShadingData prev_x3 = loadShadingData(prev_reservoir.rcNextVertexHit, float3(0.0), prev_reservoir.rcNextVertexWi);
//         float prev_d34 = prev_reservoir.rcNextVertexPathLength;
//         float prev_rcPathLength = prev_reservoir.rcVertexPathLength;
//         VertexData v_prev  = gScene.getVertexData(prev_reservoir.rcVertexHit.getTriangleHit());
        
//         // (2) prev
//         float pHat_proxy_prev_as_prev = luminance(prev_reservoir.f);

//         float3 curr_prefix_throughput = float3(1.0);
//         if(prev_reservoir.rcVertexBounce > 1){
//             reconstructPrefix(
//                 prev_reservoir.rcVertexBounce,
//                 prev_reservoir.initRandomSeed,
//                 curr_x1,
//                 curr_x1_mi,
//                 curr_d01,
//                 curr_prefix_throughput,
//                 sg
//             );
//         }

//         float l_prev = prev_rcPathLength + length(v_prev.posW - prev_x3.posW) + prev_d34;
//         float l_prev_as_curr = curr_d01 + length(curr_x1.posW - v_prev.posW) + length(v_prev.posW - prev_x3.posW) + prev_d34;
//         float dt_prev = (l_prev + dt_target) - l_prev_as_curr;
//         float tol_prev = max(abs(dt_prev) * 0.01, 1e-6);

//         float jacobian2 = 0.0;
//         HitInfo y_prev_as_curr = transient_shift_mapping(
//             curr_x1, prev_reservoir.rcVertexHit, prev_x3, dt_prev, jacobian2, debugInfo, tol_prev, sg);

        
//         VertexData v_prev_as_curr = gScene.getVertexData(y_prev_as_curr.getTriangleHit());
//         ShadingData y_prev_as_curr_sd = loadShadingData(
//             y_prev_as_curr, curr_x1.posW, normalize(v_prev_as_curr.posW - curr_x1.posW));


//         float l_prev_as_curr2 = curr_d01 + length(curr_x1.posW - y_prev_as_curr_sd.posW) 
//             + length(y_prev_as_curr_sd.posW - prev_x3.posW) + prev_d34;
//         float dt_prev2 = (l_prev + dt_target) - l_prev_as_curr2;
//         let prev_x3_mi = gScene.materials.getMaterialInstance(prev_x3, ExplicitLodTextureSampler(0));
//         float3 f_prev_as_curr = curr_prefix_throughput * getPHat3(
//             curr_x1, curr_x1_mi, y_prev_as_curr_sd,
//             prev_x3, prev_x3_mi, curr_d01, prev_d34, curr_t, 
//             prev_reservoir.rcNextVertexIrradiance, sg);
//         f_prev_as_curr *= checkVisibility(curr_x1.posW, y_prev_as_curr_sd.posW);
//         if(prev_reservoir.rcVertexBounce == 0){
//             f_prev_as_curr = 0.0;
//         }

//         float m_prev = 0.0;
//         float pHat_proxy_prev_as_curr = 0.0;
//         if(jacobian2 > 0.0){
//             pHat_proxy_prev_as_curr = luminance(f_prev_as_curr);
//             float nom = M_prev * pHat_proxy_prev_as_prev / jacobian2;
//             float denom = nom + M_curr * pHat_proxy_prev_as_curr;
//             m_prev = (denom == 0.0) ? 0.0 : nom / denom;
//         }
//         float weight_prev = m_prev * pHat_proxy_prev_as_curr * prev_reservoir.W * jacobian2;
//         if(new_reservoir.update(f_prev_as_curr, weight_prev, M_prev, sg)){
//             new_reservoir.rcVertexHit = y_prev_as_curr;
//             new_reservoir.rcNextVertexHit = prev_reservoir.rcNextVertexHit;
//             new_reservoir.rcNextVertexWi = prev_reservoir.rcNextVertexWi;
//             new_reservoir.rcNextVertexIrradiance = prev_reservoir.rcNextVertexIrradiance;
//             new_reservoir.rcNextVertexPathLength = prev_reservoir.rcNextVertexPathLength;
//             new_reservoir.rcVertexPathLength = curr_d01 + length(curr_x1.posW - v_prev_as_curr.posW);
//             new_reservoir.rcVertexBounce = prev_reservoir.rcVertexBounce;
//             new_reservoir.initRandomSeed = prev_reservoir.initRandomSeed;
//         }
//     } else {
//         new_reservoir.M += M_prev;
//     }

//     return;
// }

// this shifts curr to other.
void combine_reservoir_with_shiftmapping(
    inout Reservoir dst_reservoir,
    Reservoir curr_reservoir,
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    const float other_t,
    const float curr_t,
    bool is_curr_canonical,
    inout SampleGenerator sg
){
    ShiftMapDebugInfo debugInfo;
    float dt_target = curr_t - other_t;

    // no valid sample in reservoir
    if(curr_reservoir.W == 0.0)
    {
        dst_reservoir.M += curr_reservoir.M;
        return;
    }
    
    VertexData v_curr  = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
        
    float curr_d34 = curr_reservoir.rcNextVertexPathLength;
    float curr_rcPathLength = curr_reservoir.rcVertexPathLength;
    
    // (2) curr as other
    // (2-1) reconstruct prefix
    float3 other_prefix_throughput = float3(1.0);
    if(curr_reservoir.rcVertexBounce > 1){
        reconstructPrefix(
            curr_reservoir.rcVertexBounce,
            curr_reservoir.initRandomSeed,
            other_x1,
            other_x1_mi,
            other_d01,
            other_prefix_throughput
        );
    }
    ShadingData curr_x3 = loadShadingData(curr_reservoir.rcNextVertexHit, float3(0.0), curr_reservoir.rcNextVertexWi);
    let curr_x3_mi = gScene.materials.getMaterialInstance(curr_x3, ExplicitLodTextureSampler(0));

    // (2-2) perform shiftmap
    // evaluate distance movement
    float l_curr = curr_rcPathLength + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float l_curr_as_other = other_d01 + length(other_x1.posW - v_curr.posW) + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float dt_curr = (l_curr - dt_target) - l_curr_as_other;
    float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);
    
    // evaluate path-length aware shift mapping
    float jacobian = 0.0;
    HitInfo y_curr_as_other = transient_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3,
            dt_curr, jacobian,
            debugInfo, tol_curr, sg);

    // load information at new point
    VertexData v_curr_as_other = gScene.getVertexData(y_curr_as_other.getTriangleHit());
    ShadingData y_curr_as_other_sd = loadShadingData(
            y_curr_as_other, other_x1.posW,
            normalize(v_curr_as_other.posW - other_x1.posW));
    
    // evaluate new path throughput
    float3 f_curr_as_other = other_prefix_throughput * getPHat3(
            other_x1, other_x1_mi,
            y_curr_as_other_sd, 
            curr_x3, curr_x3_mi,
            other_d01, curr_d34, other_t, 
            curr_reservoir.rcNextVertexIrradiance, sg);
    
    f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);
    if(curr_reservoir.rcVertexBounce == 0 || jacobian == 0.0){
        f_curr_as_other = 0.0;
    }
    float pHat_proxy_curr_as_other = luminance(f_curr_as_other);
    float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);
    float M_curr = curr_reservoir.M;
    
    float nom = M_curr * pHat_proxy_curr_as_curr;
    float denom = nom + M_other * pHat_proxy_curr_as_other * jacobian;
    float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

    if(is_curr_canonical){
        float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
        if(dst_reservoir.update(curr_reservoir.f, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
            dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
            dst_reservoir.rcNextVertexWi = curr_reservoir.rcNextVertexWi;
            dst_reservoir.rcNextVertexIrradiance = curr_reservoir.rcNextVertexIrradiance;
            dst_reservoir.rcNextVertexPathLength = curr_reservoir.rcNextVertexPathLength;
            dst_reservoir.rcVertexPathLength = curr_reservoir.rcVertexPathLength;
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
        }
    } else {
        float weight = mis_weight * pHat_proxy_curr_as_other * curr_reservoir.W * jacobian;
        if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = y_curr_as_other;
            dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
            dst_reservoir.rcNextVertexWi = curr_reservoir.rcNextVertexWi;
            dst_reservoir.rcNextVertexIrradiance = curr_reservoir.rcNextVertexIrradiance;
            dst_reservoir.rcNextVertexPathLength = curr_reservoir.rcNextVertexPathLength;
            dst_reservoir.rcVertexPathLength = other_d01 + length(other_x1.posW - v_curr_as_other.posW);
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
        }
    }
}

float evaluate_canonical_shiftmap_weight(
    Reservoir curr_reservoir,
    ShadingData curr_x3,
    const VertexData v_curr,
    IMaterialInstance curr_x3_mi,
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    const float other_t,
    const float curr_t,
    inout SampleGenerator sg
)
{
    float M_curr = curr_reservoir.M;

    float dt_target = curr_t - other_t;
    ShiftMapDebugInfo debugInfo;

    if(curr_reservoir.W > 0){
        // (1) Reconstruct prefix
        float3 other_prefix_throughput = float3(1.0);
        if(curr_reservoir.rcVertexBounce > 1){
            reconstructPrefix(
                curr_reservoir.rcVertexBounce,
                curr_reservoir.initRandomSeed,
                other_x1,
                other_x1_mi,
                other_d01,
                other_prefix_throughput
            );
        }

        // (2-2) perform path-length aware shiftmap
        float l_curr = curr_reservoir.rcVertexPathLength + length(v_curr.posW - curr_x3.posW) + curr_reservoir.rcNextVertexPathLength;
        float l_curr_as_other = other_d01 + length(other_x1.posW - v_curr.posW) + length(v_curr.posW - curr_x3.posW) + curr_reservoir.rcNextVertexPathLength;
        float dt_curr = (l_curr - dt_target) - l_curr_as_other;
        float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);        
        float jacobian = 0.0;
        HitInfo y_curr_as_other = transient_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3, dt_curr, jacobian, debugInfo, tol_curr, sg);

        VertexData v_curr_as_other = gScene.getVertexData(y_curr_as_other.getTriangleHit());
        
        ShadingData y_curr_as_other_sd = loadShadingData(
            y_curr_as_other, other_x1.posW,
            normalize(v_curr_as_other.posW - other_x1.posW));

        float3 f_curr_as_other = other_prefix_throughput * getPHat3(
            other_x1, other_x1_mi,
            y_curr_as_other_sd, 
            curr_x3, curr_x3_mi,
            other_d01, curr_reservoir.rcNextVertexPathLength, other_t, 
            curr_reservoir.rcNextVertexIrradiance, sg);

        f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);

        if(curr_reservoir.rcVertexBounce == 0){
            f_curr_as_other = 0.0;
        }

        float pHat_proxy_curr_as_other = (jacobian == 0.0) ? 0.0 : luminance(f_curr_as_other);
        float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);

        float nom = M_curr * pHat_proxy_curr_as_curr;
        float denom = nom + M_other * pHat_proxy_curr_as_other * jacobian;
        float m_curr = (denom == 0.0) ? 0.0 : nom / denom;
        return m_curr;
    }
    
    return 0.0f;
}