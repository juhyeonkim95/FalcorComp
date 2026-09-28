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

import RenderPasses.Shared.Shaders.ReSTIR.PathReconstruction;
import RenderPasses.Shared.Shaders.ShiftMapping.ShiftMapping;

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
uint4 finalizeReuseStatistics(uint4 stats, float mappingJacobian, float jacobian, float target)
{
    if (stats.z == 0)
        stats.x = uint(mappingJacobian > 0.f) & uint(isfinite(mappingJacobian));
    stats.z = 1;
    stats.y = uint(stats.x > 0) & uint(jacobian > 0.f) & uint(target > 0.f) & uint(isfinite(target));
    return stats;
}
#endif

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

// Path notation as in Reservoir: camera -> ... -> a -> x -> y -> ... -> light, with x the reconnection vertex.
// The suffix of a reservoir's path: the vertex y after x (a surface, or the point light at `lightPosition`), the
// optical length after y and the light arriving at y.
struct ReconnectionSuffix
{
    ShadingData vertex;
    IMaterialInstance material; // Only if isSurface.
    bool isSurface;
    float length;
    float3 irradiance;
};

ReconnectionSuffix loadReconnectionSuffix(Reservoir reservoir, float3 lightPosition, float3 lightDirection)
{
    ReconnectionSuffix suffix;
#if IS_LIGHT_SOURCE_LASER
    suffix.isSurface = true; // A laser path ends on the lit surface.
#else
    suffix.isSurface = reservoir.rcNextVertexHit.isValid();
#endif
    if (suffix.isSurface)
    {
        suffix.vertex = loadShadingData(reservoir.rcNextVertexHit, float3(0.f), reservoir.rcNextVertexWi);
        suffix.material = gScene.materials.getMaterialInstance(suffix.vertex, ExplicitLodTextureSampler(0.f));
    }
    else
    {
        suffix.vertex.posW = lightPosition;
        suffix.vertex.frontFacing = true;
        suffix.vertex.faceN = lightDirection;
    }
    suffix.length = reservoir.rcNextVertexPathLength;
    suffix.irradiance = reservoir.rcNextVertexIrradiance;
    return suffix;
}

// A source path moved onto a target pixel's camera prefix: the shifted reconnection vertex x, its target function f
// (zero without support) and the area Jacobian.
struct ShiftedPath
{
    HitInfo hit;
    ShadingData vertex;
    float3 f;
    float jacobian;
    float mappingJacobian; // Jacobian of the shift mapping alone (debug statistics).
    float totalPathLength;
};

// Shift the reconnection vertex x of `source` (gate sourceGate) to the camera prefix of another pixel (primary hit
// `primary` at optical length primaryLength, gate targetGate), keeping the suffix. K scales the path length offset
// from the gate center (gate-width ratio). Returns false if the prefix cannot be replayed there.
bool shiftToPrefix(Reservoir source, VertexData x, ReconnectionSuffix suffix, float sourceGate,
    ShadingData primary, IMaterialInstance primaryMaterial, float primaryLength, float targetGate, float K,
    ReconnectionCriteria criteria, inout SampleGenerator sg, inout ShiftMappingDebugInfo debugInfo, out ShiftedPath shifted)
{
    // Replay the camera prefix in the target pixel, from its primary hit to a.
    ShadingData a = primary;
    IMaterialInstance aMaterial = primaryMaterial;
    float prefixLength = primaryLength;
    float3 prefixThroughput = float3(1.f);
    if (!reconstructPrefix(source.rcVertexBounce, source.initRandomSeed, a, aMaterial, prefixLength, prefixThroughput,
            criteria))
    {
        shifted.jacobian = 0.f;
        return false;
    }

    float targetLength = prefixLength + length(a.posW - x.posW) + length(x.posW - suffix.vertex.posW) + suffix.length;
    float dt = K * (source.totalPathLength - sourceGate) + targetGate - targetLength;
    float tol = max(abs(dt) * gNewtonRelativeTolerance, 1e-6f);
    float jacobian = 0.f;
    shifted.hit = pathLengthAwareShiftMapping(a, source.rcVertexHit, suffix.vertex, dt, jacobian, debugInfo, tol, sg);
    shifted.mappingJacobian = jacobian;
    jacobian *= K;
    // A rejected/non-finite shift must have zero support, not NaN weight.
    jacobian = select(isfinite(jacobian), max(jacobian, 0.f), 0.f);

    float3 shiftedPosition = gScene.getVertexData(shifted.hit.getTriangleHit()).posW;
    shifted.vertex = loadShadingData(shifted.hit, a.posW, normalize(shiftedPosition - a.posW));
    shifted.totalPathLength = prefixLength + length(a.posW - shiftedPosition)
        + length(shiftedPosition - suffix.vertex.posW) + suffix.length;

    // A moved x must still qualify as a reconnection vertex.
    let shiftedMaterial = gScene.materials.getMaterialInstance(shifted.vertex, ExplicitLodTextureSampler(0.f));
    jacobian *= float(criteria.isRough(shiftedMaterial.getProperties(shifted.vertex).roughness) &&
        criteria.isLongEnough(length(shiftedPosition - a.posW)));
    shifted.jacobian = jacobian;

    shifted.f = prefixThroughput * evalReconnectionTarget(a, aMaterial, shifted.vertex, suffix.vertex, suffix.material,
        prefixLength, suffix.length, targetGate, suffix.irradiance, sg, suffix.isSurface, K,
        source.rcNextVertexBounce > 0);
    shifted.f *= checkVisibility(a, shifted.vertex);
    if (source.rcVertexBounce == 0 || jacobian == 0.f)
        shifted.f = 0.f;
    return true;
}

// Stream `source` (otherMass: the mass of the other reservoir in the pair) into `destination` with its pairwise MIS
// weight. A canonical source keeps its own sample and only evaluates the other pixel's support; any other source
// is shifted to the destination pixel (primary hit `primary`, gate targetGate).
void combineReservoirWithShiftMapping(
    inout Reservoir destination,
    Reservoir source,
    float otherMass,
    ReconnectionCriteria criteria,
    ShadingData primary,
    IMaterialInstance primaryMaterial,
    float primaryLength,
    const float targetGate,
    const float sourceGate,
    const float K,
    bool isCanonical,
    float3 lightPosition,  // The point light, when the suffix ends there.
    float3 lightDirection,
    inout SampleGenerator sg
#if DEBUG_NEWTON_ITERATIONS
    , inout ShiftMappingDebugInfo debugInfo
#endif
#if IS_SCENE_DYNAMIC
    , bool updateLight = false, float3 targetLightPower = float3(0.f), float targetLightCosAngle = 0.f
#endif
){
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
    debugInfo.mappingDistance = float2(0.f);
#else
    ShiftMappingDebugInfo debugInfo;
#endif

    // No valid sample.
    if (source.W == 0.f)
    {
        destination.M += source.M;
        return;
    }

    // A path without a reconnection vertex cannot be shifted; only the canonical side keeps it.
    if (source.W > 0 && source.rcVertexBounce == 0)
    {
        if (isCanonical)
        {
            float weight = getReservoirWeight(source.f) * source.W;
            if (destination.update(source.f, weight, source.M, sg))
                destination.rcVertexBounce = 0;
        }
        else
            destination.M += source.M;
        return;
    }

    // Keep the source target f and full length intact for pairwise MIS and the shift dt.
    Reservoir suffixSource = source;
#if IS_SCENE_DYNAMIC
    // Slang/HLSL logical operators must not guard calls with inout side effects.
    // Spatial/shrink callers pass updateLight=false and must keep cached lighting.
    if (updateLight)
    {
        bool lightValid = reevaluateSuffixLighting(suffixSource,
            LaserLightSampler(lightPosition, lightDirection, targetLightCosAngle, targetLightPower), sg);
        if (!lightValid)
        {
            combineUnsupportedShift(destination, source, isCanonical, sg);
            return;
        }
    }
#endif
    VertexData x = gScene.getVertexData(source.rcVertexHit.getTriangleHit());
    ReconnectionSuffix suffix = loadReconnectionSuffix(suffixSource, lightPosition, lightDirection);

    ShiftedPath shifted;
    if (!shiftToPrefix(source, x, suffix, sourceGate, primary, primaryMaterial, primaryLength, targetGate, K,
            criteria, sg, debugInfo, shifted))
    {
        combineUnsupportedShift(destination, source, isCanonical, sg);
        return;
    }
#if IS_SCENE_DYNAMIC
    if (updateLight)
    {
        if (suffixSource.rcNextVertexBounce > 0)
            shifted.f *= checkVisibility(shifted.vertex, suffix.vertex);
        else
        {
            SampleGenerator lightRng = SampleGenerator(suffixSource.lightRandomSeed);
            LaserLightSampler sampler =
                LaserLightSampler(lightPosition, lightDirection, targetLightCosAngle, targetLightPower);
            LightSample light = {};
            sampler.generateLightSample(lightRng, light);
            shifted.f *= light.valid ? float(checkLightVisibility(shifted.vertex, light)) : 0.f;
        }
    }
#endif
    float shiftedTarget = getReservoirWeight(shifted.f);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = finalizeReuseStatistics(
        debugInfo.newtonStats, shifted.mappingJacobian, shifted.jacobian, shiftedTarget);
#endif

    float sourceTarget = getReservoirWeight(source.f);
    float misWeight = spatialPairCoefficient(source.M, sourceTarget, otherMass, shiftedTarget, shifted.jacobian);

    if (isCanonical)
    {
        float weight = misWeight * sourceTarget * source.W;
        if (destination.update(source.f, weight, source.M, sg))
        {
            copyReconnectionPayload(destination, source);
            destination.rcVertexHit = source.rcVertexHit;
            destination.totalPathLength = source.totalPathLength;
        }
    }
    else
    {
        float weight = misWeight * shiftedTarget * source.W * shifted.jacobian;
        if (destination.update(shifted.f, weight, source.M, sg))
        {
            copyReconnectionPayload(destination, suffixSource);
            destination.rcVertexHit = shifted.hit;
            destination.totalPathLength = shifted.totalPathLength;
        }
    }
}

// Pairwise MIS weight of the canonical sample of `source` against another pixel (mass otherMass, primary hit
// `primary`, gate targetGate). x and suffix are the source's reconnection vertex and suffix (loadReconnectionSuffix).
float evaluateCanonicalShiftWeight(
    Reservoir source,
    ReconnectionSuffix suffix,
    const VertexData x,
    float otherMass,
    ReconnectionCriteria criteria,
    ShadingData primary,
    IMaterialInstance primaryMaterial,
    float primaryLength,
    const float targetGate,
    const float sourceGate,
    inout SampleGenerator sg,
    inout ShiftMappingDebugInfo debugInfo
)
{
    // Cannot be shared with the other pixel.
    if (source.W > 0 && source.rcVertexBounce == 0)
        return 1.f;
    if (!(source.W > 0))
        return 0.f;

    ShiftedPath shifted;
    if (!shiftToPrefix(source, x, suffix, sourceGate, primary, primaryMaterial, primaryLength, targetGate, 1.f,
            criteria, sg, debugInfo, shifted))
        return 1.f;
    return spatialPairCoefficient(source.M, getReservoirWeight(source.f),
        otherMass, getReservoirWeight(shifted.f), shifted.jacobian);
}

// One side of a pairwise merge: its camera prefix (primary hit and optical length to it), gate center, and the
// light for suffixes ending at the point light (and for dynamic re-evaluation).
struct ReuseDomain
{
    ShadingData primary;
    IMaterialInstance material;
    float primaryLength;
    float gate;
    float3 lightPosition;
    float3 lightDirection;
    float3 lightPower;
    float lightCosAngle;
};

// Pairwise MIS merge of a canonical reservoir with another one. K is the canonical/other gate-width ratio (the
// shift to the canonical domain maps L to gate + K (L - otherGate)). With updateLight (dynamic scenes), each
// shifted suffix is re-lit with its target domain's light. Both reservoirs must have W set; the result has W set.
Reservoir mergeReservoirPair(Reservoir canonical, ReuseDomain canonicalDomain, Reservoir other, ReuseDomain otherDomain,
    float K, bool updateLight, ReconnectionCriteria criteria, inout SampleGenerator rng)
{
    Reservoir merged = Reservoir();
#if DEBUG_NEWTON_ITERATIONS
    // Merges are excluded from the spatial-reuse diagnostic outputs.
    ShiftMappingDebugInfo debugInfo = {};
#endif
    // Other -> canonical.
    combineReservoirWithShiftMapping(merged, other, canonical.M, criteria,
        canonicalDomain.primary, canonicalDomain.material, canonicalDomain.primaryLength,
        canonicalDomain.gate, otherDomain.gate, K, false,
        canonicalDomain.lightPosition, canonicalDomain.lightDirection, rng
#if DEBUG_NEWTON_ITERATIONS
        , debugInfo
#endif
#if IS_SCENE_DYNAMIC
        , updateLight, canonicalDomain.lightPower, canonicalDomain.lightCosAngle
#endif
    );
    // Canonical -> other evaluates competing support, retaining the canonical sample.
    combineReservoirWithShiftMapping(merged, canonical, other.M, criteria,
        otherDomain.primary, otherDomain.material, otherDomain.primaryLength,
        otherDomain.gate, canonicalDomain.gate, 1.f / K, true,
        otherDomain.lightPosition, otherDomain.lightDirection, rng
#if DEBUG_NEWTON_ITERATIONS
        , debugInfo
#endif
#if IS_SCENE_DYNAMIC
        , updateLight, otherDomain.lightPower, otherDomain.lightCosAngle
#endif
    );
    // The canonical no-RC branch copies only f and its flag; keep the selected length too.
    if (merged.rcVertexBounce == 0) merged.totalPathLength = canonical.totalPathLength;
    merged.finalizeW();
    return merged;
}
