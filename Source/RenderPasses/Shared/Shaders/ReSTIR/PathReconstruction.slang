import Utils.Color.ColorHelpers;
import RenderPasses.Shared.Shaders.Utils.TimeGate;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Rendering.Lights.LightHelpers;
import RenderPasses.Shared.Shaders.ReSTIR.Reservoirs;
#include "Utils/Math/MathConstants.slangh"
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.Utils.RayUtils;

// Path notation as in Reservoir: camera -> ... -> a -> x -> y -> ... -> light, with x the reconnection vertex.
// Target function of a path through a -> x -> y: the BSDFs at a, x and y, the inverse squared distances of a-x and
// x-y, the cosine at x, the suffix payload `irradiance`, and the time gate at gateCenter for the optical length
// prefixLength + |x - a| + |y - x| + suffixLength. Visibility and the camera prefix throughput are not included.
// y is the point light if !yIsSurface; yIsSampledSurface: generation sampled y from x (a surface).
float3 evalReconnectionTarget(
    const ShadingData a,
    const IMaterialInstance aMaterial,
    const ShadingData x,
    const ShadingData y,
    const IMaterialInstance yMaterial,
    const float prefixLength,
    const float suffixLength,
    const float gateCenter,
    const float3 irradiance,
    inout SampleGenerator sg,
    bool yIsSurface = true,
    const float K = 1.0,
    bool yIsSampledSurface = false
){
    // The gate first: outside it the target is zero, and the BSDFs need not be evaluated.
    float distance = prefixLength + length(x.posW - a.posW) + length(y.posW - x.posW) + suffixLength;
    float gate = pathLengthImportance(distance, gateCenter, K > 1);
    if (gate == 0.f) return float3(0.f);
    let xMaterial = gScene.materials.getMaterialInstance(x, ExplicitLodTextureSampler(0));

    const float3 ax = x.posW - a.posW;
    const float3 yx = x.posW - y.posW;
    const float3 wax = normalize(ax);
    const float3 wyx = normalize(yx);
    float3 fa = aMaterial.eval(a, wax, sg);
    float3 fx = xMaterial.eval(x, -wyx, sg);
    float3 fy;
    if (yIsSurface)
    {
        fy = yMaterial.eval(y, wyx, sg);
        if (yIsSampledSurface)
        {
            // Generation converts the x->y PDF with y's geometric normal.
            // Reciprocal BSDF evaluation includes its shading cosine instead.
            float shadingCosine = abs(dot(yMaterial.getProperties(y).guideNormal, wyx));
            float geometricCosine = max(dot(y.getOrientedFaceNormal(), wyx), 0.f);
            if (!(shadingCosine > 0.f)) return float3(0.f);
            fy = (fy / shadingCosine) * geometricCosine;
        }
    }
    else
        fy = dot(y.getOrientedFaceNormal(), wyx) > 0.0 ? float3(1.0) : float3(0.0);

    float cosX = max(dot(x.getOrientedFaceNormal(), -wax), 0.0);
    if (cosX < 1e-6)
        return float3(0.0);

    float distSqrAX = max(dot(ax, ax), kMinLightDistSqr);
    float distSqrXY = max(dot(yx, yx), kMinLightDistSqr);

    float3 f = fa * fx * fy * cosX / (distSqrAX * distSqrXY) * irradiance;
    if (any(isinf(f) || isnan(f))) f = 0.f;
    f *= gate;
    return f;
}

bool checkVisibility(const ShadingData source, const ShadingData target)
{
    float3 direction = target.posW - source.posW;
    // Offset each surface toward the other endpoint, including transmission connections.
    float3 origin = rayOriginToward(source, direction);
    float3 endpoint = rayOriginToward(target, -direction);
    float3 segment = endpoint - origin;
    float distance = length(segment);
    if (!(distance > 0.f) || isinf(distance) || !(dot(segment, direction) > 0.f)) return false;
    Ray visibilityRay = Ray(origin, segment / distance, 0.f, distance);
    SceneRayQuery<USE_ALPHA_TEST> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

// When x can be a reconnection vertex: the segment a -> x joins two vertices rougher than roughnessThreshold and is
// longer than minDistance. Very short segments make the target (1 / |a - x|^2) and the shift nearly singular.
struct ReconnectionCriteria
{
    float roughnessThreshold;
    float minDistance;

    bool isRough(float roughness) { return roughness > roughnessThreshold; }
    bool isLongEnough(float segmentLength) { return segmentLength > minDistance; }
};

// Replay the camera prefix of a path whose reconnection vertex x is at depth targetBounce (primary hit: depth 0) from
// another pixel's primary hit `a`, with the BSDF samples of the path (initRandomSeed). On success, `a` is the vertex
// before x, prefixLength the optical length up to it and prefixThroughput the BSDF weights. Fails if the replayed
// path would have chosen another reconnection vertex, or if `a` does not qualify for reconnection.
bool reconstructPrefix(
    uint targetBounce, uint initRandomSeed,
    inout ShadingData a, inout IMaterialInstance aMaterial,
    inout float prefixLength, inout float3 prefixThroughput,
    ReconnectionCriteria criteria)
{
    SampleGenerator rng = SampleGenerator(initRandomSeed);
    for (uint depth = 1; depth < targetBounce; ++depth)
    {
        bool previousDiffuse = criteria.isRough(aMaterial.getProperties(a).roughness);
        BSDFSample bs = {};
        if (!aMaterial.sample(a, rng, bs, USE_IMPORTANCE_SAMPLING != 0))
        {
            prefixThroughput = 0.f;
            return false;
        }
        prefixThroughput *= bs.weight;
        Ray ray = Ray(a.computeRayOrigin(!bs.isLobe(LobeType::Transmission)), bs.wo, 0.f, FLT_MAX);
        SceneRayQuery<0> query;
        float hitT;
        HitInfo hit = query.traceRay(ray, hitT);
        if (!hit.isValid()) { prefixThroughput = 0.f; return false; }
        float3 previousPosition = a.posW;
        float segmentIoR = a.IoR;
        a = loadShadingData(hit, ray.origin, ray.dir);
        aMaterial = gScene.materials.getMaterialInstance(a, ExplicitLodTextureSampler(0.f));
        float segmentLength = length(a.posW - previousPosition);
        prefixLength += segmentLength * segmentIoR;
        if (previousDiffuse)
        {
            if (criteria.isRough(aMaterial.getProperties(a).roughness))
            {
                if (criteria.isLongEnough(segmentLength))
                {
                    prefixThroughput = 0.f;
                    return false; // Generation would choose an earlier reconnection vertex.
                }
            }
        }
    }
    if (!(criteria.isRough(aMaterial.getProperties(a).roughness)))
    {
        prefixThroughput = 0.f;
        return false;
    }
    return true;
}

#if IS_SCENE_DYNAMIC
// Geometry/materials are fixed. Replay only the BSDF suffix with its original
// sampling frame; regenerate the terminal light sample using the same light seed.
// This updates Q and suffix length, NEVER the source f/W or source full length.
bool reevaluateSuffixLighting(inout Reservoir reservoir, LaserLightSampler lightSampler,
    inout SampleGenerator rng)
{
    SampleGenerator lightRng = SampleGenerator(reservoir.lightRandomSeed);
    LightSample light = {};
    lightSampler.generateLightSample(lightRng, light);
    if (!light.valid) return false;
    if (reservoir.rcNextVertexBounce == 0)
    {
        reservoir.rcNextVertexHit = light.hit;
        reservoir.rcNextVertexWi = light.dir;
        reservoir.rcNextVertexIrradiance = light.Li;
        reservoir.rcNextVertexPathLength = light.laserT;
        return true; // x->light visibility is checked after x has been shifted.
    }

    ShadingData surface = loadShadingData(reservoir.rcNextVertexHit, float3(0.f),
        reservoir.rcNextVertexRayDirection);
    IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
    SampleGenerator bsdfRng = SampleGenerator(reservoir.rcNextVertexRandomSeed);
    float3 suffixThroughput = float3(1.f);
    float suffixLength = 0.f;
    for (uint edge = 1; edge < reservoir.rcNextVertexBounce; ++edge)
    {
        BSDFSample sample = {};
        if (!material.sample(surface, bsdfRng, sample, USE_IMPORTANCE_SAMPLING != 0)) return false;
        if (!(sample.pdf > 0.f)) return false;
        if (edge == 1)
        {
            // Exclude y's BSDF: Q = cos_y / pdf_y * estimated incoming radiance.
            suffixThroughput *= abs(dot(material.getProperties(surface).guideNormal, sample.wo)) / sample.pdf;
            reservoir.rcNextVertexWi = -sample.wo;
        }
        else suffixThroughput *= sample.weight;
        float3 previousPosition = surface.posW;
        float segmentIoR = surface.IoR;
        float3 origin = surface.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
        SceneRayQuery<USE_ALPHA_TEST> query;
        float hitT;
        HitInfo hit = query.traceRay(Ray(origin, sample.wo, 0.f, FLT_MAX), hitT);
        if (!hit.isValid()) return false;
        surface = loadShadingData(hit, origin, sample.wo);
        material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
        suffixLength += length(surface.posW - previousPosition) * segmentIoR;
    }
    float3 segment = light.posW() - surface.posW;
    float distance = length(segment);
    if (!(distance > 0.f) || !isfinite(distance)) return false;
    float3 direction = segment / distance;
    float3 incident = light.evalLi(surface.posW, rng) * float(checkLightVisibility(surface, light));
    if (reservoir.rcNextVertexBounce == 1)
    {
        reservoir.rcNextVertexWi = -direction;
        reservoir.rcNextVertexIrradiance = incident * abs(dot(material.getProperties(surface).guideNormal, direction));
    }
    else
        reservoir.rcNextVertexIrradiance = suffixThroughput * material.eval(surface, direction, rng) * incident;
    reservoir.rcNextVertexPathLength = suffixLength + distance + light.laserT;
    return all(isfinite(reservoir.rcNextVertexIrradiance)) && isfinite(reservoir.rcNextVertexPathLength);
}
#endif

