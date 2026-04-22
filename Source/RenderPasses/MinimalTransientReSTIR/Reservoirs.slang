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


float getReservoirWeight(float3 f){
    return f.x;
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
    float rcVertexPostPathLength;
#if USE_SINGLE_CHANNEL
    float rcVertexPostIrradiance;
#else
    float3 rcVertexPostIrradiance;
#endif

    float3 rcVertexWi;
    uint rcVertexBounce;
    uint initRandomSeed;
    // float3 dummy;

    #if IS_SCENE_DYNAMIC
    uint rcVertexRandomSeed;
    uint rcVertexPostBounce;
    #endif
    
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
        this.rcVertexPostPathLength = 0.0;
        this.rcVertexPostIrradiance = 0.0;
        this.rcVertexWi = float3(0.0);
        this.rcVertexBounce = 0;
    }
};

Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
{
	Reservoir s = Reservoir();
	if(s.update(r1.f, getReservoirWeight(r1.f) * r1.W * r1.M / (r1.M + r2.M), r1.M, sg))
    {
        s.rcVertexHit = r1.rcVertexHit;
        s.rcVertexWi = r1.rcVertexWi;
        s.rcVertexPostIrradiance = r1.rcVertexPostIrradiance;
        s.rcVertexPostPathLength = r1.rcVertexPostPathLength;
        s.rcVertexBounce = r1.rcVertexBounce;
        s.initRandomSeed = r1.initRandomSeed;
    }

    if(s.update(r2.f, getReservoirWeight(r2.f) * r2.W * r2.M / (r1.M + r2.M), r2.M, sg))
    {
        s.rcVertexHit = r2.rcVertexHit;
        s.rcVertexWi = r2.rcVertexWi;
        s.rcVertexPostIrradiance = r2.rcVertexPostIrradiance;
        s.rcVertexPostPathLength = r2.rcVertexPostPathLength;
        s.rcVertexBounce = r2.rcVertexBounce;
        s.initRandomSeed = r2.initRandomSeed;
    }
    
    s.M = r1.M + r2.M;
    float pHat = getReservoirWeight(s.f);
    s.W = (pHat == 0 || s.M == 0) ? 0 : (1 / pHat) * (s.wSum);
    return s;
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



// this shifts curr to other.
void combine_reservoir_with_shiftmapping_for_dynamic_scene(
    inout Reservoir dst_reservoir,
    Reservoir curr_reservoir,   // this is transformed to other frame!
    Reservoir curr_reservoir_orig,   // this is not transformed to other frame!
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    bool check_bin_idx,
    int curr_tbin_idx,
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

    ShadingData curr_x2 = loadShadingData(curr_reservoir.rcVertexHit, float3(0.0), curr_reservoir.rcVertexWi);
    IMaterialInstance curr_x2_mi = gScene.materials.getMaterialInstance(curr_x2, ExplicitLodTextureSampler(0));

    // evaluate updated path throughput
    float3 d12 = curr_x2.posW - other_x1.posW;
    float3 v12 = normalize(d12);
    float G12 = max(dot(d12, d12), kMinLightDistSqr);
    float l12 = length(d12);

    float3 f1 = other_x1_mi.eval(other_x1, v12, sg);
    float3 f2 = curr_x2_mi.eval(curr_x2, -v12, sg);
    float3 f_curr_as_other = f1 * f2 / G12 * curr_reservoir.rcVertexPostIrradiance;
    f_curr_as_other *= other_prefix_throughput;
    
    //f_curr_as_other = curr_reservoir.f;
    // if(length(f_curr_as_other) < 1e-6){
    //     f_curr_as_other = curr_reservoir.f;
    // }
    
    // check visibility
    Ray visibilityRay = Ray(other_x1.posW, v12, 1e-4, max(l12 - 1e-4, 1e-4));
    SceneRayQuery<0> sceneRayQuery;
    bool V = sceneRayQuery.traceVisibilityRay(visibilityRay);
    f_curr_as_other *= float(V);

    // check path length is still valid
    // if(check_bin_idx){
    //     float pathLength = other_d01 + l12 + curr_reservoir.rcVertexPostPathLength;
    //     uint pathLengthIdx;
    //     float pathLengthIdxResidual;
    //     bool pathLengthIndexValid = false;
    //     if(getPathLengthIndex(pathLength, pathLengthIdx, pathLengthIdxResidual)){
    //         if(pathLengthIdx == curr_tbin_idx){
    //             pathLengthIndexValid = true;
    //         } else if (curr_tbin_idx < 0){
    //             pathLengthIndexValid = true;
    //         }
    //     }
    //     f_curr_as_other *= float(pathLengthIndexValid);
    // }

    float pHat_proxy_curr_as_other = getReservoirWeight(f_curr_as_other);

    float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir_orig.f);
    float M_curr = curr_reservoir.M;
    
    float nom = M_curr * pHat_proxy_curr_as_curr;
    float denom = nom + M_other * pHat_proxy_curr_as_other;
    float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

    if(is_curr_canonical){
        float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
        if(dst_reservoir.update(curr_reservoir_orig.f, weight, M_curr, sg)){
            dst_reservoir.rcVertexHit = curr_reservoir_orig.rcVertexHit;
            dst_reservoir.rcVertexWi = curr_reservoir_orig.rcVertexWi;
            dst_reservoir.rcVertexPostIrradiance = curr_reservoir_orig.rcVertexPostIrradiance;
            dst_reservoir.rcVertexPostPathLength = curr_reservoir_orig.rcVertexPostPathLength;
            dst_reservoir.rcVertexBounce = curr_reservoir_orig.rcVertexBounce;
            dst_reservoir.initRandomSeed = curr_reservoir_orig.initRandomSeed;
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


// this shifts curr to other.
void combine_reservoir_with_shiftmapping(
    inout Reservoir dst_reservoir,
    Reservoir curr_reservoir,
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    bool check_bin_idx,
    int curr_tbin_idx,
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
    
    VertexData curr_v2 = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
    float3 d12 = curr_v2.posW - other_x1.posW;
    float3 v12 = normalize(d12);
    ShadingData curr_x2 = loadShadingData(curr_reservoir.rcVertexHit, other_x1.posW, v12 );
    IMaterialInstance curr_x2_mi = gScene.materials.getMaterialInstance(curr_x2, ExplicitLodTextureSampler(0));
    
    float G12 = max(dot(d12, d12), kMinLightDistSqr);
    float l12 = length(d12);

    float3 f1 = other_x1_mi.eval(other_x1, v12, sg);
    // float3 f1 = other_x1_mi.eval(other_x1, v12, sg);
    // float f1pdf = other_x1_mi.evalPdf(other_x1, v12);
    // if(f1pdf>0)f1 /= f1pdf;
    
    float3 f2 = curr_x2_mi.eval(curr_x2, -curr_reservoir.rcVertexWi, sg);
    float n21 = abs(dot(curr_x2.faceN, v12));
    if(n21 < 1e-6){n21 = 0.0;}
    float3 f_curr_as_other = f1 * f2 * n21 / G12 * curr_reservoir.rcVertexPostIrradiance;
    // f_curr_as_other = curr_reservoir.f;


    // ShadingData curr_x2 = loadShadingData(curr_reservoir.rcVertexHit, other_x1.posW, d12);
    // IMaterialInstance curr_x2_mi = gScene.materials.getMaterialInstance(curr_x2, ExplicitLodTextureSampler(0));

    // float3 v12 = normalize(d12);
    // float G12 = max(dot(d12, d12), kMinLightDistSqr);
    // float l12 = length(d12);

    // float3 f1 = other_x1_mi.eval(other_x1, v12, sg);
    // float f1pdf = other_x1_mi.evalPdf(other_x1, v12);
    // if(f1pdf>0)f1 /= f1pdf;
    
    // // float3 f1 = other_x1_mi.getProperties(other_x1).diffuseReflectionAlbedo;

    // float3 f2 = curr_x2_mi.eval(curr_x2, -curr_reservoir.rcVertexWi, sg);
    // float3 f_curr_as_other = f1 * f2 * curr_reservoir.rcVertexPostIrradiance;

    
    // ShadingData curr_x2 = loadShadingData(curr_reservoir.rcVertexHit, float3(0.0), curr_reservoir.rcVertexWi);
    // IMaterialInstance curr_x2_mi = gScene.materials.getMaterialInstance(curr_x2, ExplicitLodTextureSampler(0));

    // // evaluate updated path throughput
    // float3 d12 = curr_x2.posW - other_x1.posW;
    // float3 v12 = normalize(d12);
    // float G12 = max(dot(d12, d12), kMinLightDistSqr);
    // float l12 = length(d12);

    // float3 f1 = other_x1_mi.eval(other_x1, v12, sg);
    // float3 f2 = curr_x2_mi.eval(curr_x2, -v12, sg);
    // float3 f_curr_as_other = f1 * f2 / G12 * curr_reservoir.rcVertexPostIrradiance;
    // f_curr_as_other *= other_prefix_throughput;
    
    // float r = abs((f_curr_as_other - curr_reservoir.f) / (curr_reservoir.f)).x;
    // if (r > 2 || r < 0.5){
    //     return;
    // }

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
    if(check_bin_idx){
        float pathLength = other_d01 + l12 + curr_reservoir.rcVertexPostPathLength;
        uint pathLengthIdx;
        float pathLengthIdxResidual;
        bool pathLengthIndexValid = false;
        if(getPathLengthIndex(pathLength, pathLengthIdx, pathLengthIdxResidual)){
            if(pathLengthIdx == curr_tbin_idx){
                pathLengthIndexValid = true;
            } else if (curr_tbin_idx < 0){
                pathLengthIndexValid = true;
            }
        }
        f_curr_as_other *= float(pathLengthIndexValid);
    }

    float pHat_proxy_curr_as_other = getReservoirWeight(f_curr_as_other);

    float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
    float M_curr = curr_reservoir.M;
    
    float nom = M_curr * pHat_proxy_curr_as_curr;
    float denom = nom + M_other * pHat_proxy_curr_as_other;
    float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

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
    // SampleGenerator light_sg = SampleGenerator(reservoir.lightRandomSeed);
    lls.generateLightSample(sg, ls);

    VertexData v1 = gScene.getVertexData(reservoir.rcVertexHit.getTriangleHit());

    // rcNextHit is Light
    if(reservoir.rcVertexBounce == 1){
        reservoir.rcVertexWi = normalize(v1.posW - ls.posW());
        reservoir.rcVertexPostPathLength = length(v1.posW - ls.posW()) + ls.laserT;
        #if USE_SINGLE_CHANNEL
        reservoir.rcVertexPostIrradiance = getReservoirWeight(ls.evalLi(v1.posW, sg));
        #else
        reservoir.rcVertexPostIrradiance = ls.evalLi(v1.posW, sg);
        #endif
        return;
    }

    // Otherwise, we need to 
    // trace new ray starting from rcNextVertex
    
    ShadingData sd = loadShadingData(reservoir.rcVertexHit, float3(0.0), reservoir.rcVertexWi);
    IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    float3 postfixThroughput = float3(1.0);
    float postfixPathLength = 0.0;

    float3 rcNextVertexWi = reconstructPostfix(
        reservoir.rcVertexBounce, 
        reservoir.rcVertexRandomSeed,
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
    
    #if USE_SINGLE_CHANNEL
    reservoir.rcVertexPostIrradiance = getReservoirWeight(postfixf);
    #else
    reservoir.rcVertexPostIrradiance = postfixf;
    #endif
    reservoir.rcVertexPostPathLength = postfixPathLengthFull;
}
#endif


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

