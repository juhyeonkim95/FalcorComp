import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import TransientShiftmapping;
import LoadShadingData;
import Scene.RaytracingInline;
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import LaserLightSampler;
import Rendering.Lights.LightHelpers;


static const bool kUseSingleChannel = false;


float getReservoirWeight(float3 f){
#if USE_SINGLE_CHANNEL
    return f.x;
#else
    return luminance(f);
#endif
}

float getReservoirWeight(float f){
    return f;
}


struct Reservoir
{
#if USE_SINGLE_CHANNEL
    float f;
#else
    float3 f;
#endif
    float wSum;
    float M;
    float W;

    HitInfo rcVertexHit;
    HitInfo rcNextVertexHit;
    float3 rcNextVertexWi;
    float3 rcNextVertexIrradiance;
    float rcNextVertexPathLength;
    float totalPathLength;

    uint rcVertexBounce;
    uint initRandomSeed;

    // if scene is dynamic, we need to FULL retrace the ray after rtVertexNext
    #if IS_SCENE_DYNAMIC
    uint rcNextVertexBounce;
    uint rcNextVertexRandomSeed;
    uint lightRandomSeed;
    #endif

    // TODO add layered material
    // uint initLobe;
    // uint rcVertexLobe;
    // uint rcNextVertexLobe;

    [mutating]
    bool update(float3 newf, float weight, float M, inout SampleGenerator sg){
        this.wSum += weight;
        this.M += M;
        if(sampleNext1D(sg) * this.wSum < weight){
            #if USE_SINGLE_CHANNEL
            this.f = getReservoirWeight(newf);
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
        this.rcNextVertexWi = float3(1,0,0);
        this.rcNextVertexIrradiance = float3(0.0);
        this.rcNextVertexPathLength = 0.0;
        this.rcVertexBounce = 0;
        this.totalPathLength = 0;
        #if IS_SCENE_DYNAMIC
        this.rcNextVertexBounce = 0;
        #endif
    }
};

Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
{
	Reservoir s = Reservoir();
	s.update(r1.f, getReservoirWeight(r1.f) * r1.W * r1.M / (r1.M + r2.M), r1.M, sg);
    s.update(r2.f, getReservoirWeight(r2.f) * r2.W * r2.M / (r1.M + r2.M), r2.M, sg);
    // s.M = r1.M + r2.M;
    float pHat = getReservoirWeight(s.f);
    s.W = (pHat == 0 || s.M == 0) ? 0 : (1 / pHat) * (s.wSum);
    return s;
}


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
    inout SampleGenerator sg,
    bool isMi3valid=true
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
    // const float d12 = length(p2 - p1);
    // const float d23 = length(p2 - p3);

    // float eps = 1e-4;   // scene dependent!
    // float d12 = max(length(p2 - p1), eps);
    // float d23 = max(length(p3 - p2), eps);

    float3 f1 = mi1.eval(sd1, v12, sg);
    float3 f2 = mi2.eval(sd2, -v32, sg);
    float3 f3;
    if(isMi3valid){
        f3 = mi3.eval(sd3, v32, sg);
    } else {
        f3 = dot(sd3.getOrientedFaceNormal(), v32) > 0.0 ? float3(1.0) : float3(0.0);
    }

    float n21 = max(dot(n2, -v12), 0.0);
    if(n21 < 1e-6)
        return float3(0.0);

    float G12 = max(dot(l12, l12), kMinLightDistSqr);
    float G23 = max(dot(l32, l32), kMinLightDistSqr);

    float3 f = f1 * f2 * f3 * n21 / (G12 * G23) * irradiance;
    if (any(isinf(f) || isnan(f))) f = 0.f;
    float distance = d01 + length(p2 - p1) + length(p3 - p2) + d34;
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
        // sampleNext2D(sg_new); // for light sampling
        // sampleNext1D(sg_new); // for reservoir update

        prefixThroughput *= bsdfSample.weight;

        Ray ray = Ray(x1.computeRayOrigin(!is_transmission), bsdfSample.wo, 0.f, FLT_MAX);
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

float3 reconstructPostfix(
    uint targetBounce,
    uint initRandomSeed,
    inout ShadingData x1,
    inout IMaterialInstance x1_mi,
    inout float d01,
    inout float3 prefixThroughput
)
{
    if (targetBounce <= 1) return float3(1.0);

    HitInfo hit;
    float   hitT;
    BSDFSample bsdfSample;
    SampleGenerator sg_new = SampleGenerator(initRandomSeed);
    float3 wi;

    for (uint depth = 1; depth < targetBounce; depth++)
    {
        x1_mi.sample(x1, sg_new, bsdfSample, true);
        if(depth == 1){
            wi = -bsdfSample.wo;
        }
        bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

        // Keep RNG streams aligned with main integrator.
        // sampleNext2D(sg_new); // for light sampling
        // sampleNext1D(sg_new); // for reservoir update

        prefixThroughput *= bsdfSample.weight;

        Ray ray = Ray(x1.computeRayOrigin(!is_transmission), bsdfSample.wo, 0.f, FLT_MAX);
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
    return wi;
}


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
    float3 laserPosition,   // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    float3 laserDirection,  // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    inout SampleGenerator sg
){
    ShiftMapDebugInfo debugInfo;

    // no valid sample in reservoir
    if(curr_reservoir.W == 0.0)
    {
        dst_reservoir.M += curr_reservoir.M;
        return;
    }

    // sample cannot be shared with other. (update only for canonical)
    if(curr_reservoir.W > 0 && curr_reservoir.rcVertexBounce == 0){
        if(is_curr_canonical){
            float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
            float weight = 1.0 * pHat_proxy_curr_as_curr * curr_reservoir.W;
            if(dst_reservoir.update(curr_reservoir.f, weight, curr_reservoir.M, sg)){
                dst_reservoir.rcVertexBounce = 0;
            }
        } else {
            dst_reservoir.M += curr_reservoir.M;
        }
        return;
    }

    VertexData v_curr = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
        
    float curr_d34 = curr_reservoir.rcNextVertexPathLength;
    
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

    ShadingData curr_x3;
    IMaterialInstance curr_x3_mi;
    #if IS_LIGHT_SOURCE_LASER
    bool isRCNextNotPointLight = true;
    #else
    bool isRCNextNotPointLight = curr_reservoir.rcNextVertexHit.isValid();
    #endif
    
    // rcNextVertexHit is not a point light
    if(isRCNextNotPointLight){
        curr_x3 = loadShadingData(curr_reservoir.rcNextVertexHit, float3(0.0), curr_reservoir.rcNextVertexWi);
        curr_x3_mi = gScene.materials.getMaterialInstance(curr_x3, ExplicitLodTextureSampler(0));
    } else {
        curr_x3.posW = laserPosition;
        curr_x3.frontFacing = true;
        curr_x3.faceN = laserDirection;
    }

    // (2-2) perform shiftmap
    // evaluate distance movement
    float l_curr = curr_reservoir.totalPathLength;
    float l_curr_as_other = other_d01 + length(other_x1.posW - v_curr.posW) + length(v_curr.posW - curr_x3.posW) + curr_d34;
    
    float l_target = (l_curr - curr_t) + other_t;
    float dt_curr = l_target - l_curr_as_other;

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
            curr_reservoir.rcNextVertexIrradiance, sg, isRCNextNotPointLight);
        
    f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);
    if(curr_reservoir.rcVertexBounce == 0 || jacobian == 0.0){
        f_curr_as_other = 0.0;
    }
    float pHat_proxy_curr_as_other = getReservoirWeight(f_curr_as_other);

    float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
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
            
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
            dst_reservoir.totalPathLength = curr_reservoir.totalPathLength;
            #if IS_SCENE_DYNAMIC
            dst_reservoir.rcNextVertexBounce = curr_reservoir.rcNextVertexBounce;
            dst_reservoir.rcNextVertexRandomSeed = curr_reservoir.rcNextVertexRandomSeed;
            dst_reservoir.lightRandomSeed = curr_reservoir.lightRandomSeed;
            #endif
        }
    } else {
        float weight = mis_weight * pHat_proxy_curr_as_other * curr_reservoir.W * jacobian;
        if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = y_curr_as_other;
            dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
            dst_reservoir.rcNextVertexWi = curr_reservoir.rcNextVertexWi;
            dst_reservoir.rcNextVertexIrradiance = curr_reservoir.rcNextVertexIrradiance;
            dst_reservoir.rcNextVertexPathLength = curr_reservoir.rcNextVertexPathLength;
            
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
            dst_reservoir.totalPathLength = other_d01 + length(other_x1.posW - v_curr_as_other.posW)
                 + length(v_curr_as_other.posW - curr_x3.posW) + curr_d34;
            #if IS_SCENE_DYNAMIC
            dst_reservoir.rcNextVertexBounce = curr_reservoir.rcNextVertexBounce;
            dst_reservoir.rcNextVertexRandomSeed = curr_reservoir.rcNextVertexRandomSeed;
            dst_reservoir.lightRandomSeed = curr_reservoir.lightRandomSeed;
            #endif
        }
    }
}

// this shifts curr to other.
void combine_reservoir_with_shiftmapping_for_dynamic_scene(
    inout Reservoir dst_reservoir,
    Reservoir curr_reservoir,   // this is transformed to other frame!
    Reservoir curr_reservoir_orig,   // this is not transformed to other frame!
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    const float other_t,
    const float curr_t,
    bool is_curr_canonical,
    float3 laserPosition,
    float3 laserDirection,
    // out float moved_distance,
    inout SampleGenerator sg
){
    // moved_distance = 0.0;

    ShiftMapDebugInfo debugInfo;

    // no valid sample in reservoir
    if(curr_reservoir_orig.W == 0.0)
    {
        dst_reservoir.M += curr_reservoir_orig.M;
        return;
    }

    // sample cannot be shared with other. (update only for canonical)
    if(curr_reservoir_orig.W > 0 && curr_reservoir_orig.rcVertexBounce == 0){
        if(is_curr_canonical){
            float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir_orig.f);
            float weight = 1.0 * pHat_proxy_curr_as_curr * curr_reservoir_orig.W;
            if(dst_reservoir.update(curr_reservoir_orig.f, weight, curr_reservoir_orig.M, sg)){
                dst_reservoir.rcVertexBounce = 0;
            }
        } else {
            dst_reservoir.M += curr_reservoir_orig.M;
        }
        return;
    }
    VertexData v_curr = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());

    // float3 v_curr_posW;
    // if(is_curr_canonical){
    //     v_curr_posW = gScene.getPrevPosW(curr_reservoir.rcVertexHit);
    // } else {
        
    //     v_curr_posW = 
    // }

    float curr_d34 = curr_reservoir.rcNextVertexPathLength;
    
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

    ShadingData curr_x3;
    IMaterialInstance curr_x3_mi;
    #if IS_LIGHT_SOURCE_LASER
    bool isRCNextNotPointLight = true;
    #else
    bool isRCNextNotPointLight = curr_reservoir.rcNextVertexHit.isValid();
    #endif

    // rcNextVertexHit is not a point light
    if(isRCNextNotPointLight){
        curr_x3 = loadShadingData(curr_reservoir.rcNextVertexHit, float3(0.0), curr_reservoir.rcNextVertexWi);
        curr_x3_mi = gScene.materials.getMaterialInstance(curr_x3, ExplicitLodTextureSampler(0));
    } else {
        curr_x3.posW = laserPosition;
        curr_x3.frontFacing = true;
        curr_x3.faceN = laserDirection;
    }

    // (2-2) perform shiftmap
    // evaluate distance movement
    // float l_curr = curr_reservoir.rcVertexPathLength + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float l_curr_as_other = other_d01 + length(other_x1.posW - v_curr.posW) + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float l_curr = curr_reservoir_orig.totalPathLength;

    float l_target = (l_curr - curr_t) + other_t;
    float dt_curr = l_target - l_curr_as_other;

    float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);
    
    // evaluate path-length aware shift mapping
    float jacobian = 0.0;
    
    HitInfo y_curr_as_other = transient_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3,
            dt_curr, jacobian,
            debugInfo, tol_curr, sg);
    // jacobian = 1.0;
    // y_curr_as_other = curr_reservoir.rcVertexHit;

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
            curr_reservoir.rcNextVertexIrradiance, sg, isRCNextNotPointLight);
        
    f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);
    if(curr_reservoir_orig.rcVertexBounce == 0 || jacobian == 0.0){
        f_curr_as_other = 0.0;
    }
    float pHat_proxy_curr_as_other = getReservoirWeight(f_curr_as_other);

    float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir_orig.f);
    float M_curr = curr_reservoir_orig.M;
    
    float nom = M_curr * pHat_proxy_curr_as_curr;
    float denom = nom + M_other * pHat_proxy_curr_as_other * jacobian;
    float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

    if(is_curr_canonical){
        float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir_orig.W;
        if(dst_reservoir.update(curr_reservoir_orig.f, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = curr_reservoir_orig.rcVertexHit;
            dst_reservoir.rcNextVertexHit = curr_reservoir_orig.rcNextVertexHit;
            dst_reservoir.rcNextVertexWi = curr_reservoir_orig.rcNextVertexWi;
            dst_reservoir.rcNextVertexIrradiance = curr_reservoir_orig.rcNextVertexIrradiance;
            dst_reservoir.rcNextVertexPathLength = curr_reservoir_orig.rcNextVertexPathLength;
            dst_reservoir.totalPathLength = curr_reservoir_orig.totalPathLength;
            
            dst_reservoir.rcVertexBounce = curr_reservoir_orig.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir_orig.initRandomSeed;
            #if IS_SCENE_DYNAMIC
            dst_reservoir.rcNextVertexBounce = curr_reservoir_orig.rcNextVertexBounce;
            dst_reservoir.rcNextVertexRandomSeed = curr_reservoir_orig.rcNextVertexRandomSeed;
            dst_reservoir.lightRandomSeed = curr_reservoir_orig.lightRandomSeed;
            #endif
        }
    } else {
        float weight = mis_weight * pHat_proxy_curr_as_other * curr_reservoir.W * jacobian;
        if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = y_curr_as_other;
            dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
            dst_reservoir.rcNextVertexWi = curr_reservoir.rcNextVertexWi;
            dst_reservoir.rcNextVertexIrradiance = curr_reservoir.rcNextVertexIrradiance;
            dst_reservoir.rcNextVertexPathLength = curr_reservoir.rcNextVertexPathLength;
            
            dst_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir.initRandomSeed;
            dst_reservoir.totalPathLength = other_d01 + length(other_x1.posW - v_curr_as_other.posW) + length(v_curr_as_other.posW - curr_x3.posW) + curr_d34;
            #if IS_SCENE_DYNAMIC
            dst_reservoir.rcNextVertexBounce = curr_reservoir.rcNextVertexBounce;
            dst_reservoir.rcNextVertexRandomSeed = curr_reservoir.rcNextVertexRandomSeed;
            dst_reservoir.lightRandomSeed = curr_reservoir_orig.lightRandomSeed;
            #endif
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
    
    // this cannot be shared with other.
    if(curr_reservoir.W > 0 && curr_reservoir.rcVertexBounce == 0){
        return 1.0;
    }

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
        float l_curr = curr_reservoir.totalPathLength;//curr_reservoir.rcVertexPathLength + length(v_curr.posW - curr_x3.posW) + curr_reservoir.rcNextVertexPathLength;
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
            curr_reservoir.rcNextVertexIrradiance, sg, curr_reservoir.rcNextVertexHit.isValid());

        f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);

        if(curr_reservoir.rcVertexBounce == 0){
            f_curr_as_other = 0.0;
        }

        float pHat_proxy_curr_as_other = (jacobian == 0.0) ? 0.0 : getReservoirWeight(f_curr_as_other);
        float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);

        float nom = M_curr * pHat_proxy_curr_as_curr;
        float denom = nom + M_other * pHat_proxy_curr_as_other * jacobian;
        float m_curr = (denom == 0.0) ? 0.0 : nom / denom;
        return m_curr;
    }
    
    return 0.0f;
}


#if IS_SCENE_DYNAMIC
// check needed to be updated in dynamic scene:
void update_reservoir_for_dynamic_scene(
    inout Reservoir reservoir,
    LaserLightSampler lls,
    inout SampleGenerator sg
){
    if(reservoir.rcVertexBounce == 0){
        return;
    }

    // sample light
    LightSample ls;
    SampleGenerator light_sg = SampleGenerator(reservoir.lightRandomSeed);
    lls.generateLightSample(light_sg, ls);

    // rcNextHit is Light
    if(reservoir.rcNextVertexBounce == 0){
        reservoir.rcNextVertexHit = ls.hit;
        reservoir.rcNextVertexWi = ls.dir;
        reservoir.rcNextVertexPathLength = ls.laserT;
        reservoir.rcNextVertexIrradiance = ls.Li;
        return;
    }

    // Otherwise, we need to 
    // trace new ray starting from rcNextVertex
    VertexData v1 = gScene.getVertexData(reservoir.rcVertexHit.getTriangleHit());
    VertexData v2 = gScene.getVertexData(reservoir.rcNextVertexHit.getTriangleHit());
    
    ShadingData sd = loadShadingData(reservoir.rcNextVertexHit, float3(0.0), normalize(v2.posW - v1.posW));
    IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    float3 postfixThroughput = float3(1.0);
    float postfixPathLength = 0.0;

    float3 rcNextVertexWi = reconstructPostfix(
        reservoir.rcNextVertexBounce, 
        reservoir.rcNextVertexRandomSeed,
        sd,
        mi,
        postfixPathLength,
        postfixThroughput
    );

    float3 toLightDir = normalize(ls.posW() - sd.posW);
    float toLightDist = length(ls.posW() - sd.posW);

    Ray visibilityRay = Ray(sd.computeRayOrigin(), toLightDir, 0.0, toLightDist - 1e-3f);
    SceneRayQuery<0> sceneShadowRayQuery;
    bool V = sceneShadowRayQuery.traceVisibilityRay(visibilityRay);
    
    float3 L_light = ls.evalLi(sd.posW, sg) * float(V);

    float3 postfixf = postfixThroughput * L_light * max(0.0, dot(sd.getOrientedFaceNormal(), toLightDir));
    float postfixPathLengthFull = postfixPathLength + toLightDist + ls.laserT;
    
    reservoir.rcNextVertexWi = (reservoir.rcNextVertexBounce == 1) ? -toLightDir : rcNextVertexWi;
    reservoir.rcNextVertexPathLength = postfixPathLengthFull;
    reservoir.rcNextVertexIrradiance = postfixf;
}
#endif

