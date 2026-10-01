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
import RenderPasses.Shared.Shaders.ShiftMapping.NewtonSolver;

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
    destination.rcPrevVertexPosition = source.rcPrevVertexPosition;
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
    float3 prefixEnd; // a on the target prefix.
    float3 f;
    float jacobian;
    float mappingJacobian; // Jacobian of the shift mapping alone (debug statistics).
    float totalPathLength;
};

// Shift the reconnection vertex x of `source` (gate sourceGate) to the camera prefix of another pixel (primary hit
// `primary` at optical length primaryLength, gate targetGate), keeping the suffix. The shift uses the source path's
// own endpoints of x: its stored a (rcPrevVertexPosition) and sourceNext (its y). K scales the path length
// offset from the gate center (gate-width ratio). Returns false if the prefix cannot be replayed there.
bool shiftToPrefix(Reservoir source, VertexData x, ReconnectionSuffix suffix, ShadingData sourceNext,
    float sourceGate, ShadingData primary, IMaterialInstance primaryMaterial, float primaryLength, float targetGate,
    float K, ReconnectionCriteria criteria, inout SampleGenerator sg, inout ShiftMappingDebugInfo debugInfo,
    out ShiftedPath shifted)
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

    // Each path's length besides its two segments at x: the source's prefix up to a_s and suffix from y_s (from its
    // stored total), and the target's prefix up to a plus the suffix from y.
    float sourceRest = source.totalPathLength - length(source.rcPrevVertexPosition - x.posW)
        - length(x.posW - sourceNext.posW);
    ShiftLengthCondition condition = { K, sourceGate, targetGate, sourceRest, prefixLength + suffix.length };
    float jacobian = 0.f;
    ShiftSource shiftSource = makeShiftSource(source.rcPrevVertexPosition, sourceNext, a, suffix.vertex);
    VertexData shiftedData;
    shifted.hit = pathLengthAwareShiftMapping(a, source.rcVertexHit, x, suffix.vertex, shiftSource, condition,
        jacobian, shiftedData, debugInfo, sg);
    shifted.prefixEnd = a.posW;
    shifted.mappingJacobian = jacobian;
    jacobian *= K;
    // A rejected/non-finite shift must have zero support, not NaN weight.
    jacobian = select(isfinite(jacobian), max(jacobian, 0.f), 0.f);
    if (jacobian == 0.f)
    {
        // No support: skip the moved path's evaluation (and its visibility ray). shifted.vertex is left unset.
        shifted.jacobian = 0.f;
        shifted.f = 0.f;
        shifted.totalPathLength = source.totalPathLength;
        return true;
    }

    float3 shiftedPosition = shiftedData.posW;
    shifted.vertex = loadShadingData(shifted.hit.getTriangleHit(), shiftedData, normalize(shiftedPosition - a.posW));
    shifted.totalPathLength = prefixLength + length(a.posW - shiftedPosition)
        + length(shiftedPosition - suffix.vertex.posW) + suffix.length;

    // A moved x must still qualify as a reconnection vertex.
    let shiftedMaterial = gScene.materials.getMaterialInstance(shifted.vertex, ExplicitLodTextureSampler(0.f));
    jacobian *= float(criteria.isRough(shiftedMaterial.getProperties(shifted.vertex).roughness) &&
        criteria.isLongEnough(length(shiftedPosition - a.posW)));
    shifted.jacobian = jacobian;
    if (source.rcVertexBounce == 0 || jacobian == 0.f)
    {
        shifted.f = 0.f;
        return true;
    }

    shifted.f = prefixThroughput * evalReconnectionTarget(a, aMaterial, shifted.vertex, suffix.vertex, suffix.material,
        prefixLength, suffix.length, targetGate, suffix.irradiance, sg, suffix.isSurface, K,
        source.rcNextVertexBounce > 0);
    // A zero target (e.g. outside the gate) needs no visibility ray.
    if (any(shifted.f != 0.f)) shifted.f *= checkVisibility(a, shifted.vertex);
    return true;
}

// What a non-canonical source with a static suffix contributes to a pairwise merge: only its mass (no sample, no
// reconnection vertex, or no shift), or its shifted path with its RIS weight. evaluateIncomingCandidate computes it and
// streamIncomingCandidate adds it to a reservoir, so the two can run in separate passes.
static const uint kIncomingMassOnly = 0;
static const uint kIncomingSample = 1;
struct IncomingCandidate
{
    HitInfo hit;            // Shifted x.
    float3 f;               // Target of the shifted path.
    float weight;           // RIS weight: pairwise MIS coefficient * target * source W * Jacobian.
    float3 prefixEnd;       // a on the target prefix.
    float totalPathLength;  // Of the shifted path.
    uint kind;              // kIncomingMassOnly or kIncomingSample.
};

// Shift `source` (otherMass: the mass of the other reservoir in the pair) to the destination pixel (primary hit
// `primary`, gate targetGate), keeping its suffix.
IncomingCandidate evaluateIncomingCandidate(
    Reservoir source,
    float otherMass,
    ReconnectionCriteria criteria,
    ShadingData primary,
    IMaterialInstance primaryMaterial,
    float primaryLength,
    const float targetGate,
    const float sourceGate,
    const float K,
    float3 lightPosition,  // The point light, when the suffix ends there.
    float3 lightDirection,
    inout SampleGenerator sg,
    inout ShiftMappingDebugInfo debugInfo
)
{
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
    debugInfo.mappingDistance = float2(0.f);
#endif
    IncomingCandidate candidate = {};
    candidate.kind = kIncomingMassOnly;
    // No valid sample, or a path without a reconnection vertex: it cannot be shifted.
    if (source.W == 0.f) return candidate;
    if (source.W > 0 && source.rcVertexBounce == 0) return candidate;

    VertexData x = gScene.getVertexData(source.rcVertexHit.getTriangleHit());
    ReconnectionSuffix suffix = loadReconnectionSuffix(source, lightPosition, lightDirection);
    ShiftedPath shifted;
    if (!shiftToPrefix(source, x, suffix, suffix.vertex, sourceGate, primary, primaryMaterial, primaryLength,
            targetGate, K, criteria, sg, debugInfo, shifted))
        return candidate;
    float shiftedTarget = getReservoirWeight(shifted.f);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = finalizeReuseStatistics(
        debugInfo.newtonStats, shifted.mappingJacobian, shifted.jacobian, shiftedTarget);
#endif
    float misWeight = spatialPairCoefficient(source.M, getReservoirWeight(source.f), otherMass, shiftedTarget,
        shifted.jacobian);
    candidate.kind = kIncomingSample;
    candidate.f = shifted.f;
    candidate.weight = misWeight * shiftedTarget * source.W * shifted.jacobian;
    candidate.hit = shifted.hit;
    candidate.prefixEnd = shifted.prefixEnd;
    candidate.totalPathLength = shifted.totalPathLength;
    return candidate;
}

// Stream a candidate of `source` (from evaluateIncomingCandidate) into `destination`.
void streamIncomingCandidate(inout Reservoir destination, IncomingCandidate candidate, Reservoir source,
    inout SampleGenerator sg)
{
    if (candidate.kind == kIncomingMassOnly)
    {
        destination.M += source.M;
        return;
    }
    if (destination.update(candidate.f, candidate.weight, source.M, sg))
    {
        copyReconnectionPayload(destination, source);
        destination.rcVertexHit = candidate.hit;
        destination.rcPrevVertexPosition = candidate.prefixEnd;
        destination.totalPathLength = candidate.totalPathLength;
    }
}

// What the canonical source of a pairwise merge contributes with a static suffix: only its mass (no sample), its
// sample without a reconnection vertex (which the other domain cannot have), or its sample with the pairwise MIS
// weight against the other domain (weight as if alone when the shift there fails). evaluateCanonicalCandidate computes
// it and streamCanonicalCandidate adds it to a reservoir, so the two can run in separate passes.
static const uint kCanonicalMassOnly = 0;
static const uint kCanonicalLocalSample = 1;
static const uint kCanonicalSample = 2;
struct CanonicalCandidate
{
    float weight; // RIS weight: pairwise MIS coefficient * target * source W.
    uint kind;    // kCanonicalMassOnly, kCanonicalLocalSample or kCanonicalSample.
};

// Evaluate the canonical `source` against the other domain (otherMass: the other reservoir's mass; primary hit
// `primary`, gate targetGate) by shifting its path there.
CanonicalCandidate evaluateCanonicalCandidate(
    Reservoir source,
    float otherMass,
    ReconnectionCriteria criteria,
    ShadingData primary,
    IMaterialInstance primaryMaterial,
    float primaryLength,
    const float targetGate,
    const float sourceGate,
    const float K,
    float3 lightPosition,  // The point light, when the suffix ends there.
    float3 lightDirection,
    inout SampleGenerator sg,
    inout ShiftMappingDebugInfo debugInfo
)
{
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
    debugInfo.mappingDistance = float2(0.f);
#endif
    CanonicalCandidate candidate = {};
    candidate.kind = kCanonicalMassOnly;
    if (source.W == 0.f) return candidate;
    float sourceTarget = getReservoirWeight(source.f);
    if (source.W > 0 && source.rcVertexBounce == 0)
    {
        candidate.kind = kCanonicalLocalSample;
        candidate.weight = sourceTarget * source.W;
        return candidate;
    }

    VertexData x = gScene.getVertexData(source.rcVertexHit.getTriangleHit());
    ReconnectionSuffix suffix = loadReconnectionSuffix(source, lightPosition, lightDirection);
    candidate.kind = kCanonicalSample;
    ShiftedPath shifted;
    if (!shiftToPrefix(source, x, suffix, suffix.vertex, sourceGate, primary, primaryMaterial, primaryLength,
            targetGate, K, criteria, sg, debugInfo, shifted))
    {
        candidate.weight = sourceTarget * source.W;
        return candidate;
    }
    float shiftedTarget = getReservoirWeight(shifted.f);
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = finalizeReuseStatistics(
        debugInfo.newtonStats, shifted.mappingJacobian, shifted.jacobian, shiftedTarget);
#endif
    float misWeight = spatialPairCoefficient(source.M, sourceTarget, otherMass, shiftedTarget, shifted.jacobian);
    candidate.weight = misWeight * sourceTarget * source.W;
    return candidate;
}

// Stream the canonical `source` (with its candidate from evaluateCanonicalCandidate) into `destination`. A sample
// without a reconnection vertex carries only its target f and the flag.
void streamCanonicalCandidate(inout Reservoir destination, CanonicalCandidate candidate, Reservoir source,
    inout SampleGenerator sg)
{
    if (candidate.kind == kCanonicalMassOnly)
    {
        destination.M += source.M;
        return;
    }
    if (!destination.update(source.f, candidate.weight, source.M, sg)) return;
    if (candidate.kind == kCanonicalLocalSample)
    {
        destination.rcVertexBounce = 0;
        return;
    }
    copyReconnectionPayload(destination, source);
    destination.rcVertexHit = source.rcVertexHit;
    destination.totalPathLength = source.totalPathLength;
}

// One pair of a pairwise merge, evaluated in its own pass (two-pass spatial and temporal reuse) for a later pass to
// stream: the incoming candidate of the other reservoir (with that reservoir's M) and the canonical sample's side.
// 64 bytes.
struct ReusePair
{
    HitInfo hit;           // IncomingCandidate fields.
    float3 f;
    float weight;
    float3 prefixEnd;
    float totalPathLength;
    float canonical;       // Spatial: the canonical pairwise coefficient; temporal: the CanonicalCandidate weight.
    float sourceM;         // M of the other reservoir.
    uint status;           // IncomingCandidate kind; temporal: | CanonicalCandidate kind << 8.
};

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
    , float3 sourceLightPosition = float3(0.f), float3 sourceLightDirection = float3(0.f)
#endif
){
#if DEBUG_NEWTON_ITERATIONS
    debugInfo.newtonStats = uint4(0);
    debugInfo.mappingDistance = float2(0.f);
#else
    ShiftMappingDebugInfo debugInfo;
#endif

    // A static suffix: evaluate and stream the candidate. Re-lit suffixes (updateLight) are handled below.
#if IS_SCENE_DYNAMIC
    if (!updateLight)
#endif
    {
        if (isCanonical)
        {
            CanonicalCandidate candidate = evaluateCanonicalCandidate(source, otherMass, criteria, primary,
                primaryMaterial, primaryLength, targetGate, sourceGate, K, lightPosition, lightDirection, sg, debugInfo);
            streamCanonicalCandidate(destination, candidate, source, sg);
        }
        else
        {
            IncomingCandidate candidate = evaluateIncomingCandidate(source, otherMass, criteria, primary,
                primaryMaterial, primaryLength, targetGate, sourceGate, K, lightPosition, lightDirection, sg, debugInfo);
            streamIncomingCandidate(destination, candidate, source, sg);
        }
        return;
    }

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

    // The source path's own y. A re-lit suffix may start at another y (a moved light); then the source's y is its
    // original next vertex, or the source frame's light for a point-light endpoint.
    ShadingData sourceNext = suffix.vertex;
#if IS_SCENE_DYNAMIC
    if (updateLight)
    {
        if (source.rcNextVertexHit.isValid())
            sourceNext = loadShadingData(source.rcNextVertexHit, float3(0.f), source.rcNextVertexWi);
        else
        {
            sourceNext.posW = sourceLightPosition;
            sourceNext.frontFacing = true;
            sourceNext.faceN = sourceLightDirection;
        }
    }
#endif
    ShiftedPath shifted;
    if (!shiftToPrefix(source, x, suffix, sourceNext, sourceGate, primary, primaryMaterial, primaryLength,
            targetGate, K, criteria, sg, debugInfo, shifted))
    {
        combineUnsupportedShift(destination, source, isCanonical, sg);
        return;
    }
#if IS_SCENE_DYNAMIC
    if (updateLight && shifted.jacobian > 0.f)
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
            destination.rcPrevVertexPosition = shifted.prefixEnd;
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
    if (!shiftToPrefix(source, x, suffix, suffix.vertex, sourceGate, primary, primaryMaterial, primaryLength,
            targetGate, 1.f, criteria, sg, debugInfo, shifted))
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
        , updateLight, canonicalDomain.lightPower, canonicalDomain.lightCosAngle, otherDomain.lightPosition,
        otherDomain.lightDirection
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
        , updateLight, otherDomain.lightPower, otherDomain.lightCosAngle, canonicalDomain.lightPosition,
        canonicalDomain.lightDirection
#endif
    );
    // The canonical no-RC branch copies only f and its flag; keep the selected length too.
    if (merged.rcVertexBounce == 0) merged.totalPathLength = canonical.totalPathLength;
    merged.finalizeW();
    return merged;
}
