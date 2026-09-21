// Static reuse uses the path-length-aware mapping; legacy code remains available.
#define USE_LEGACY_SPATIAL_SHIFT 0

import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import TransientShiftmapping;
import PathLengthAwareShiftmapping;
import LoadShadingData;
import Scene.RaytracingInline;
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import LaserLightSampler;
import Rendering.Lights.LightHelpers;


static const bool kUseSingleChannel = false;


struct Reservoir
{
    // Path notation: camera -> ... -> a -> x -> y -> z -> ... -> v -> light.
    // x is the reconnection vertex; y is the next vertex toward the light.
    // When rcVertexBounce == 0, reconnection fields below are unused and may be stale.

    // Selected RGB target contribution, including the time gate.
    // During initial generation: path MC contribution (before technique MIS) * p_A for reconnectable paths,
    // where p_A contains the actual proposal area PDFs for a -> x and surface x -> y.
    // These edges may use a BSDF proposal or the terminal ellipsoidal proposal.
    // For a non-reconnectable path, stores the path MC contribution directly.
    float3 f;
    // Sum of reservoir selection weights. Initially: sum(MIS weight * luminance(path MC contribution) / samplesPerPixel).
    float wSum;
    // Accumulated candidate count/mass supplied to update(). Initially counts submitted
    // completed-path candidates across bounce depths, not the number of camera paths.
    float M;
    // Final normalization: wSum / luminance(f), or zero for a zero target.
    // The selected reservoir estimates RGB contribution as W * f.
    float W;

    // Surface hit identifying x, the first vertex passing the reconnection eligibility test.
    HitInfo rcVertexHit;
    // Surface hit identifying y. For x -> light, stores ls.hit instead;
    // a laser endpoint has a surface hit, while a point-light endpoint has an invalid hit.
    HitInfo rcNextVertexHit;
    // Light propagation direction INTO y from the suffix: normalize(y - z).
    // Opposite to the outward direction from y toward its incoming light.
    // For y -> light: normalize(y - light); for a light endpoint: ls.dir
    // (laser propagation direction, or a dummy direction for a point light).
    float3 rcNextVertexWi;
    // Static suffix payload, excluding y's BSDF, camera-prefix throughput, and time gate.
    // This is a weighted incoming-light contribution, NOT raw incoming radiance:
    // y -> light: Li(y) * incident shading cosine.
    // y -> z -> ... -> light: estimated Li(y) * incident shading cosine / original solid-angle pdf(y -> z).
    // This PDF is the BSDF or ellipse density, according to how that edge was sampled.
    // The Li estimate includes later sampled BSDF weights and final light visibility.
    // If y is the light endpoint: ls.Li (source payload).
    float3 rcNextVertexIrradiance;
    // Suffix path length from y to the source, excluding the camera prefix and x -> y.
    // Includes the laser endpoint -> source distance; for a light endpoint, equals ls.laserT.
    float rcNextVertexPathLength;
    // Full candidate camera -> source path length used to evaluate the time gate.
    float totalPathLength;

    // Camera-walk depth of x: primary surface is depth 0, first secondary hit is depth 1.
    // Zero is the sentinel for a candidate with no reconnectable vertex.
    uint rcVertexBounce;
    // BSDF RNG state before this camera path's first BSDF sample; used to replay its prefix.
    // Does not contain the separate reservoir-selection or light-sampling RNG state.
    uint initRandomSeed;

    // Number of camera-walk edges after x before the final direct light connection.
    // 0: x -> light; 1: x -> y -> light; 2: x -> y -> z -> light; etc.
    uint rcNextVertexBounce;
    #if IS_SCENE_DYNAMIC
    // BSDF RNG state immediately before sampling y -> z; assigned only when that edge exists.
    uint rcNextVertexRandomSeed;
    // Light RNG state immediately before generating this candidate's final light sample.
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
        this.totalPathLength = 0;
        this.rcNextVertexBounce = 0;
    }
};

Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
{
	Reservoir s = Reservoir();
	s.update(r1.f, luminance(r1.f) * r1.W * r1.M / (r1.M + r2.M), r1.M, sg);
    s.update(r2.f, luminance(r2.f) * r2.W * r2.M / (r1.M + r2.M), r2.M, sg);
    // s.M = r1.M + r2.M;
    float pHat = luminance(s.f);
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
    bool isMi3valid=true,
    const float K = 1.0,
    bool yIsSampledSurface = false
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
        if (yIsSampledSurface)
        {
            // Generation converts the x->y PDF with y's geometric normal.
            // Reciprocal BSDF evaluation includes its shading cosine instead.
            float shadingCosine = abs(dot(mi3.getProperties(sd3).guideNormal, v32));
            float geometricCosine = max(dot(sd3.getOrientedFaceNormal(), v32), 0.f);
            if (!(shadingCosine > 0.f)) return float3(0.f);
            f3 = (f3 / shadingCosine) * geometricCosine;
        }
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
    f *= pathLengthImportance(distance, target_dist, K > 1);

    return f;
}


bool checkVisibility(const float3 p1, const float3 p2)
{
    Ray visibilityRay = Ray(p1, normalize(p2 - p1), 0.001f, length(p1 - p2) - 0.001f);
    SceneRayQuery<0> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

bool reconstructPrefix(
    uint targetBounce, uint initRandomSeed,
    inout ShadingData x1, inout IMaterialInstance x1_mi,
    inout float d01, inout float3 prefixThroughput,
    float roughnessThreshold = 0.25f)
{
    SampleGenerator rng = SampleGenerator(initRandomSeed);
    for (uint depth = 1; depth < targetBounce; ++depth)
    {
        bool previousDiffuse = x1_mi.getProperties(x1).roughness > roughnessThreshold;
        BSDFSample bs = {};
        if (!x1_mi.sample(x1, rng, bs, USE_IMPORTANCE_SAMPLING != 0))
        {
            prefixThroughput = 0.f;
            return false;
        }
        prefixThroughput *= bs.weight;
        Ray ray = Ray(x1.computeRayOrigin(!bs.isLobe(LobeType::Transmission)), bs.wo, 0.f, FLT_MAX);
        SceneRayQuery<0> query;
        float hitT;
        HitInfo hit = query.traceRay(ray, hitT);
        if (!hit.isValid()) { prefixThroughput = 0.f; return false; }
        float3 previousPosition = x1.posW;
        x1 = loadShadingData(hit, ray.origin, ray.dir);
        x1_mi = gScene.materials.getMaterialInstance(x1, ExplicitLodTextureSampler(0.f));
        float segmentLength = length(x1.posW - previousPosition);
        d01 += segmentLength * x1.IoR;
        if (previousDiffuse)
        {
            if (x1_mi.getProperties(x1).roughness > roughnessThreshold)
            {
                if (segmentLength > 0.f)
                {
                    prefixThroughput = 0.f;
                    return false; // Generation would choose an earlier reconnection vertex.
                }
            }
        }
    }
    if (!(x1_mi.getProperties(x1).roughness > roughnessThreshold))
    {
        prefixThroughput = 0.f;
        return false;
    }
    return true;
}

// Balanced ratios with scaled mass, target and Jacobian factors. No logs and
// no reciprocal of a tiny target are needed; all products here are <= 1.
float spatialPairCoefficient(float sourceMass, float sourceTarget,
    float targetMass, float targetTarget, float J)
{
    float massScale = max(sourceMass, targetMass);
    float targetScale = max(sourceTarget, targetTarget);
    if (!(massScale > 0.f)) return 0.f;
    if (!(targetScale > 0.f)) return 0.f;
    float jScale = max(1.f, J);
    float a = (sourceMass / massScale) * (sourceTarget / targetScale) / jScale;
    float b = (targetMass / massScale) * (targetTarget / targetScale) * (J / jScale);
    return (a + b > 0.f) ? a / (a + b) : 0.f;
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
    ShadingData source_x1, IMaterialInstance source_x1_mi, float source_d01, float roughnessThreshold,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    const float other_t,
    const float curr_t,
    const float K,
    bool is_curr_canonical,
    float3 laserPosition,   // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    float3 laserDirection,  // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    inout SampleGenerator sg
#if DEBUG_NEWTON_ITERATIONS
    , inout ShiftMapDebugInfo debugInfo
#endif
){
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
#else
    ShiftMapDebugInfo debugInfo;
#endif

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

    VertexData v_curr = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
        
    float curr_d34 = curr_reservoir.rcNextVertexPathLength;
    
    // (2) curr as other
    // (2-1) reconstruct prefix
    float3 other_prefix_throughput = float3(1.f);
#if !USE_LEGACY_SPATIAL_SHIFT
    float3 source_prefix_throughput = float3(1.f);
    bool sourceValid = reconstructPrefix(curr_reservoir.rcVertexBounce, curr_reservoir.initRandomSeed,
        source_x1, source_x1_mi, source_d01, source_prefix_throughput, roughnessThreshold);
#endif
    bool targetValid = reconstructPrefix(curr_reservoir.rcVertexBounce, curr_reservoir.initRandomSeed,
        other_x1, other_x1_mi, other_d01, other_prefix_throughput, roughnessThreshold);
#if !USE_LEGACY_SPATIAL_SHIFT
    if (!sourceValid) { dst_reservoir.M += curr_reservoir.M; return; }
#endif
    if (!targetValid) { dst_reservoir.M += curr_reservoir.M; return; }

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

    float jacobian = 0.0;
    
#if USE_LEGACY_SPATIAL_SHIFT
    float targetLength = other_d01 + length(other_x1.posW - v_curr.posW)
        + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float dt = K * (curr_reservoir.totalPathLength - curr_t) + other_t - targetLength;
    float tol = max(abs(dt) * 0.01f, 1e-6f);
    HitInfo y_curr_as_other = transient_shift_mapping(
        other_x1, curr_reservoir.rcVertexHit, curr_x3, dt, jacobian, debugInfo, tol, sg);
    jacobian *= K;
#else
    HitInfo y_curr_as_other = path_lentgh_aware_shift_mapping(
        source_x1, source_d01, other_x1, other_d01, curr_reservoir.rcVertexHit,
        curr_x3, isRCNextNotPointLight, curr_d34, curr_t, other_t, K,
        curr_reservoir.initRandomSeed, jacobian, debugInfo, sg);
#endif
    // A rejected/non-finite shift must have zero support, not NaN weight.
    jacobian = select(isfinite(jacobian), max(jacobian, 0.f), 0.f);

    // load information at new point
    VertexData v_curr_as_other = gScene.getVertexData(y_curr_as_other.getTriangleHit());
    ShadingData y_curr_as_other_sd = loadShadingData(
            y_curr_as_other, other_x1.posW,
            normalize(v_curr_as_other.posW - other_x1.posW));

        // A moved x must still qualify as a reconnection vertex.
        let shiftedMaterial = gScene.materials.getMaterialInstance(y_curr_as_other_sd, ExplicitLodTextureSampler(0.f));
        jacobian *= float(shiftedMaterial.getProperties(y_curr_as_other_sd).roughness > roughnessThreshold);

    // evaluate new path throughput
    float3 f_curr_as_other = other_prefix_throughput * getPHat3(
            other_x1, other_x1_mi,
            y_curr_as_other_sd, 
            curr_x3, curr_x3_mi,
            other_d01, curr_d34, other_t, 
            curr_reservoir.rcNextVertexIrradiance, sg, isRCNextNotPointLight, K, curr_reservoir.rcNextVertexBounce > 0);
        
    f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);
    if(curr_reservoir.rcVertexBounce == 0 || jacobian == 0.0){
        f_curr_as_other = 0.0;
    }
    float pHat_proxy_curr_as_other = luminance(f_curr_as_other);
#if DEBUG_NEWTON_ITERATIONS
    // Positive finite shifted target after geometry, eligibility, gate and visibility.
    // Counts supported candidates, not whether reservoir selection chose them.
    debugInfo.newtonStats.y = uint(debugInfo.newtonStats.x > 0 && jacobian > 0.f
        && pHat_proxy_curr_as_other > 0.f && isfinite(pHat_proxy_curr_as_other));
#endif

    float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);
    float M_curr = curr_reservoir.M;
    
    float mis_weight = spatialPairCoefficient(M_curr, pHat_proxy_curr_as_curr,
        M_other, pHat_proxy_curr_as_other, jacobian);

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
            dst_reservoir.rcNextVertexBounce = curr_reservoir.rcNextVertexBounce;
            #if IS_SCENE_DYNAMIC
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
            dst_reservoir.rcNextVertexBounce = curr_reservoir.rcNextVertexBounce;
            #if IS_SCENE_DYNAMIC
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
    const float K,
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
            float pHat_proxy_curr_as_curr = luminance(curr_reservoir_orig.f);
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

    float l_target = K * (l_curr - curr_t) + other_t;
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

    jacobian *= K;

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
    float pHat_proxy_curr_as_other = luminance(f_curr_as_other);

    float pHat_proxy_curr_as_curr = luminance(curr_reservoir_orig.f);
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
            dst_reservoir.rcNextVertexBounce = curr_reservoir_orig.rcNextVertexBounce;
            #if IS_SCENE_DYNAMIC
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
            dst_reservoir.rcNextVertexBounce = curr_reservoir.rcNextVertexBounce;
            #if IS_SCENE_DYNAMIC
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
    ShadingData source_x1, IMaterialInstance source_x1_mi, float source_d01, float roughnessThreshold,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    const float other_t,
    const float curr_t,
    inout SampleGenerator sg,
    inout ShiftMapDebugInfo debugInfo
)
{
    float M_curr = curr_reservoir.M;

    
    // this cannot be shared with other.
    if(curr_reservoir.W > 0 && curr_reservoir.rcVertexBounce == 0){
        return 1.0;
    }

    if(curr_reservoir.W > 0){
        // (1) Reconstruct prefix
        float3 other_prefix_throughput = float3(1.f);
#if !USE_LEGACY_SPATIAL_SHIFT
        float3 source_prefix_throughput = float3(1.f);
        bool sourceValid = reconstructPrefix(curr_reservoir.rcVertexBounce, curr_reservoir.initRandomSeed,
            source_x1, source_x1_mi, source_d01, source_prefix_throughput, roughnessThreshold);
#endif
        bool targetValid = reconstructPrefix(curr_reservoir.rcVertexBounce, curr_reservoir.initRandomSeed,
            other_x1, other_x1_mi, other_d01, other_prefix_throughput, roughnessThreshold);
#if !USE_LEGACY_SPATIAL_SHIFT
        if (!sourceValid) { return 1.f; }
#endif
        if (!targetValid) { return 1.f; }

        float jacobian = 0.0;
#if USE_LEGACY_SPATIAL_SHIFT
        float targetLength = other_d01 + length(other_x1.posW - v_curr.posW)
            + length(v_curr.posW - curr_x3.posW) + curr_reservoir.rcNextVertexPathLength;
        float dt = (curr_reservoir.totalPathLength - curr_t) + other_t - targetLength;
        float tol = max(abs(dt) * 0.01f, 1e-6f);
        HitInfo y_curr_as_other = transient_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3, dt, jacobian, debugInfo, tol, sg);
#else
        HitInfo y_curr_as_other = path_lentgh_aware_shift_mapping(
            source_x1, source_d01, other_x1, other_d01, curr_reservoir.rcVertexHit,
            curr_x3, curr_reservoir.rcNextVertexHit.isValid(), curr_reservoir.rcNextVertexPathLength,
            curr_t, other_t, 1.f, curr_reservoir.initRandomSeed, jacobian, debugInfo, sg);
#endif
        jacobian = select(isfinite(jacobian), max(jacobian, 0.f), 0.f);

        VertexData v_curr_as_other = gScene.getVertexData(y_curr_as_other.getTriangleHit());
        
        ShadingData y_curr_as_other_sd = loadShadingData(
            y_curr_as_other, other_x1.posW,
            normalize(v_curr_as_other.posW - other_x1.posW));

        // A moved x must still qualify as a reconnection vertex.
        let shiftedMaterial = gScene.materials.getMaterialInstance(y_curr_as_other_sd, ExplicitLodTextureSampler(0.f));
        jacobian *= float(shiftedMaterial.getProperties(y_curr_as_other_sd).roughness > roughnessThreshold);

        float3 f_curr_as_other = other_prefix_throughput * getPHat3(
            other_x1, other_x1_mi,
            y_curr_as_other_sd, 
            curr_x3, curr_x3_mi,
            other_d01, curr_reservoir.rcNextVertexPathLength, other_t, 
            curr_reservoir.rcNextVertexIrradiance, sg, curr_reservoir.rcNextVertexHit.isValid(), 1.f, curr_reservoir.rcNextVertexBounce > 0);

        f_curr_as_other *= checkVisibility(other_x1.posW, y_curr_as_other_sd.posW);

        if(curr_reservoir.rcVertexBounce == 0){
            f_curr_as_other = 0.0;
        }

        if(length(f_curr_as_other) == 0.0){
            debugInfo.status = 1;
        }

        float pHat_proxy_curr_as_other = (jacobian == 0.0) ? 0.0 : luminance(f_curr_as_other);
        float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);

        return spatialPairCoefficient(M_curr, pHat_proxy_curr_as_curr,
            M_other, pHat_proxy_curr_as_other, jacobian);
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

