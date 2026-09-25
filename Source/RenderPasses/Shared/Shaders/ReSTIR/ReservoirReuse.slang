import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Rendering.Lights.LightHelpers;
import RenderPasses.Shared.Shaders.ReSTIR.Reservoirs;
#include "Utils/Math/MathConstants.slangh"
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;

import RenderPasses.Shared.Shaders.ReSTIR.PathReconstruction;
import RenderPasses.Shared.Shaders.ReSTIR.PathLengthAwareShiftmapping;

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

#if DEBUG_NEWTON_ITERATIONS
// Keep counter-only control flow separate from the material/reservoir update.
// Slang 2024.1.34 can loop in simplifyCFG with this bookkeeping in combine().
uint4 finalize_reuse_statistics(uint4 stats, float mappingJacobian, float jacobian, float target)
{
    if (stats.z == 0)
        stats.x = uint(mappingJacobian > 0.f) & uint(isfinite(mappingJacobian));
    stats.z = 1;
    stats.y = uint(stats.x > 0) & uint(jacobian > 0.f) & uint(target > 0.f) & uint(isfinite(target));
    return stats;
}
#endif

// this shifts curr to other.
// Copy the selected path payload; callers set the mapped hit and full path length.
void copyReconnectionPayload(inout Reservoir destination, const Reservoir source)
{
    destination.rcNextVertexHit = source.rcNextVertexHit;
    destination.rcNextVertexWi = source.rcNextVertexWi;
    destination.rcNextVertexIrradiance = source.rcNextVertexIrradiance;
    destination.rcNextVertexPathLength = source.rcNextVertexPathLength;
    destination.rcVertexBounce = source.rcVertexBounce;
    destination.initRandomSeed = source.initRandomSeed;
    destination.rcNextVertexBounce = source.rcNextVertexBounce;
#if IS_SCENE_DYNAMIC
    destination.rcNextVertexRandomSeed = source.rcNextVertexRandomSeed;
    destination.rcNextVertexRayDirection = source.rcNextVertexRayDirection;
    destination.lightRandomSeed = source.lightRandomSeed;
#endif
}

// A failed reverse shift means the other proposal has zero support. Keep the
// canonical sample with coefficient one; a failed incoming shift contributes zero.
void combineUnsupportedShift(inout Reservoir destination, Reservoir source, bool canonical,
    inout SampleGenerator rng)
{
    if (!canonical) { destination.M += source.M; return; }
    float weight = getReservoirWeight(source.f) * source.W;
    if (destination.update(source.f, weight, source.M, rng))
    {
        copyReconnectionPayload(destination, source);
        destination.rcVertexHit = source.rcVertexHit;
        destination.totalPathLength = source.totalPathLength;
    }
}

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
#if IS_SCENE_DYNAMIC
    , bool updateLight = false, float3 targetLightPower = float3(0.f), float targetLightCosAngle = 0.f
#endif
){
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
    debugInfo.mappingDistance = float2(0.f);
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

    // Keep the previous target f and full length intact for pairwise MIS/shift dt.
    Reservoir targetReservoir = curr_reservoir;
#if IS_SCENE_DYNAMIC
    // Slang/HLSL logical operators must not guard calls with inout side effects.
    // Spatial/shrink callers pass updateLight=false and must keep cached lighting.
    if (updateLight)
    {
        bool lightValid = reevaluateSuffixLighting(targetReservoir,
            LaserLightSampler(laserPosition, laserDirection, targetLightCosAngle, targetLightPower), sg);
        if (!lightValid)
        {
            combineUnsupportedShift(dst_reservoir, curr_reservoir, is_curr_canonical, sg);
            return;
        }
    }
#endif
    VertexData v_curr = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());

    float curr_d34 = targetReservoir.rcNextVertexPathLength;

    // Replay the camera prefix in the target pixel.
    float3 other_prefix_throughput = float3(1.f);
    bool targetValid = reconstructPrefix(curr_reservoir.rcVertexBounce, curr_reservoir.initRandomSeed,
        other_x1, other_x1_mi, other_d01, other_prefix_throughput, roughnessThreshold);
    if (!targetValid)
    {
        combineUnsupportedShift(dst_reservoir, curr_reservoir, is_curr_canonical, sg);
        return;
    }

    ShadingData curr_x3;
    IMaterialInstance curr_x3_mi;
    #if IS_LIGHT_SOURCE_LASER
    bool isRCNextNotPointLight = true;
    #else
    bool isRCNextNotPointLight = targetReservoir.rcNextVertexHit.isValid();
    #endif

    // rcNextVertexHit is not a point light
    if(isRCNextNotPointLight){
        curr_x3 = loadShadingData(targetReservoir.rcNextVertexHit, float3(0.0), targetReservoir.rcNextVertexWi);
        curr_x3_mi = gScene.materials.getMaterialInstance(curr_x3, ExplicitLodTextureSampler(0));
    } else {
        curr_x3.posW = laserPosition;
        curr_x3.frontFacing = true;
        curr_x3.faceN = laserDirection;
    }

    float jacobian = 0.0;

    float targetLength = other_d01 + length(other_x1.posW - v_curr.posW)
        + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float dt = K * (curr_reservoir.totalPathLength - curr_t) + other_t - targetLength;
    float tol = max(abs(dt) * 0.01f, 1e-6f);
    HitInfo y_curr_as_other = path_length_aware_shift_mapping(
        other_x1, curr_reservoir.rcVertexHit, curr_x3, dt, jacobian, debugInfo, tol, sg);
#if DEBUG_NEWTON_ITERATIONS
    float mappingJacobian = jacobian;
#endif
    jacobian *= K;
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
            targetReservoir.rcNextVertexIrradiance, sg, isRCNextNotPointLight, K, curr_reservoir.rcNextVertexBounce > 0);

    f_curr_as_other *= checkVisibility(other_x1, y_curr_as_other_sd);
#if IS_SCENE_DYNAMIC
    if (updateLight)
    {
        if (targetReservoir.rcNextVertexBounce > 0)
            f_curr_as_other *= checkVisibility(y_curr_as_other_sd, curr_x3);
        else
        {
            SampleGenerator lightRng = SampleGenerator(targetReservoir.lightRandomSeed);
            LaserLightSampler sampler = LaserLightSampler(laserPosition, laserDirection, targetLightCosAngle, targetLightPower);
            LightSample light = {};
            sampler.generateLightSample(lightRng, light);
            f_curr_as_other *= light.valid ? float(checkLightVisibility(y_curr_as_other_sd, light)) : 0.f;
        }
    }
#endif
    if(curr_reservoir.rcVertexBounce == 0 || jacobian == 0.0){
        f_curr_as_other = 0.0;
    }
    float pHat_proxy_curr_as_other = getReservoirWeight(f_curr_as_other);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = finalize_reuse_statistics(
        debugInfo.newtonStats, mappingJacobian, jacobian, pHat_proxy_curr_as_other);
#endif

    float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
    float M_curr = curr_reservoir.M;

    float mis_weight = spatialPairCoefficient(M_curr, pHat_proxy_curr_as_curr,
        M_other, pHat_proxy_curr_as_other, jacobian);

    if(is_curr_canonical){
        float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
        if(dst_reservoir.update(curr_reservoir.f, weight, M_curr, sg)){
            copyReconnectionPayload(dst_reservoir, curr_reservoir);
            dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;

            dst_reservoir.totalPathLength = curr_reservoir.totalPathLength;
        }
    } else {
        float weight = mis_weight * pHat_proxy_curr_as_other * curr_reservoir.W * jacobian;
        if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
            copyReconnectionPayload(dst_reservoir, targetReservoir);
            dst_reservoir.rcVertexHit = y_curr_as_other;

            dst_reservoir.totalPathLength = other_d01 + length(other_x1.posW - v_curr_as_other.posW)
                 + length(v_curr_as_other.posW - curr_x3.posW) + curr_d34;
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
        bool targetValid = reconstructPrefix(curr_reservoir.rcVertexBounce, curr_reservoir.initRandomSeed,
            other_x1, other_x1_mi, other_d01, other_prefix_throughput, roughnessThreshold);
        if (!targetValid) { return 1.f; }

        float jacobian = 0.0;
        float targetLength = other_d01 + length(other_x1.posW - v_curr.posW)
            + length(v_curr.posW - curr_x3.posW) + curr_reservoir.rcNextVertexPathLength;
        float dt = (curr_reservoir.totalPathLength - curr_t) + other_t - targetLength;
        float tol = max(abs(dt) * 0.01f, 1e-6f);
        HitInfo y_curr_as_other = path_length_aware_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3, dt, jacobian, debugInfo, tol, sg);
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

        f_curr_as_other *= checkVisibility(other_x1, y_curr_as_other_sd);

        if(curr_reservoir.rcVertexBounce == 0){
            f_curr_as_other = 0.0;
        }

        if(length(f_curr_as_other) == 0.0){
            debugInfo.status = 1;
        }

        float pHat_proxy_curr_as_other = (jacobian == 0.0) ? 0.0 : getReservoirWeight(f_curr_as_other);
        float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);

        return spatialPairCoefficient(M_curr, pHat_proxy_curr_as_curr,
            M_other, pHat_proxy_curr_as_other, jacobian);
    }

    return 0.0f;
}
