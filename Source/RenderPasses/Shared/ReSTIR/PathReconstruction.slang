import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Rendering.Lights.LightHelpers;
import RenderPasses.Shared.ReSTIR.Reservoirs;
#include "Utils/Math/MathConstants.slangh"
import RenderPasses.Shared.Utils.LoadShadingData;
import RenderPasses.Shared.Lights.LaserLightSampler;

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

bool checkVisibility(const ShadingData source, const ShadingData target)
{
    float3 direction = target.posW - source.posW;
    // Offset each surface toward the other endpoint, including transmission connections.
    float3 origin = source.computeRayOrigin(dot(source.getOrientedFaceNormal(), direction) >= 0.f);
    float3 endpoint = target.computeRayOrigin(dot(target.getOrientedFaceNormal(), -direction) >= 0.f);
    float3 segment = endpoint - origin;
    float distance = length(segment);
    if (!(distance > 0.f) || isinf(distance) || !(dot(segment, direction) > 0.f)) return false;
    Ray visibilityRay = Ray(origin, segment / distance, 0.f, distance);
    SceneRayQuery<USE_ALPHA_TEST> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

// Offset each surface endpoint toward the open segment. The point-light endpoint
// has no surface to offset. BSDFs and path lengths still use unmodified positions.
bool checkLightVisibility(ShadingData surface, LightSample light)
{
    if (!light.valid) return false;
    float3 segment = light.posW() - surface.posW;
    if (!(dot(segment, segment) > 0.f)) return false;
    float3 origin = surface.computeRayOrigin(dot(surface.getOrientedFaceNormal(), segment) >= 0.f);
    float3 endpoint = light.posW();
#if IS_LIGHT_SOURCE_LASER
    endpoint = light.sd.computeRayOrigin(dot(light.getOrientedFaceNormal(), -segment) >= 0.f);
#endif
    float3 offsetSegment = endpoint - origin;
    if (!(dot(offsetSegment, segment) > 0.f)) return false;
    float distance = length(offsetSegment);
    if (!(distance > 0.f) || !isfinite(distance)) return false;
    SceneRayQuery<USE_ALPHA_TEST> query;
    return query.traceVisibilityRay(Ray(origin, offsetSegment / distance, 0.f, distance));
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
        float3 origin = surface.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
        SceneRayQuery<USE_ALPHA_TEST> query;
        float hitT;
        HitInfo hit = query.traceRay(Ray(origin, sample.wo, 0.f, FLT_MAX), hitT);
        if (!hit.isValid()) return false;
        surface = loadShadingData(hit, origin, sample.wo);
        material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
        suffixLength += length(surface.posW - previousPosition) * surface.IoR;
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

