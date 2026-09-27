#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import RenderPasses.Shared.Shaders.Utils.TimeGate;
import Utils.Geometry.Ellipsoid;
import Utils.Geometry.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.ReSTIR.Reservoirs;
import RenderPasses.Shared.Shaders.ReSTIR.PathReconstruction;
import RenderPasses.Shared.Shaders.ReSTIR.ReservoirReuse;
import RenderPasses.Shared.Shaders.ReSTIR.InitialCandidates;
#if USE_SHRINK_MAPPING || USE_TEMPORAL_REUSE
import RenderPasses.Shared.Shaders.ShiftMapping.ShiftMapping;
#endif
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.Lights.EllipsoidalSampling;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Utils.RayUtils;


cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.

    uint samplesPerPixel;
    float specularRoughnessThreshold;
    float specularRoughnessThresholdEllipsoid;
    float gTemporalHistoryLength;
    float gRoughTimeGateSampleRatio; // Shrink mapping: fraction of the paths traced with the wide gate, in [0, 1].
#if USE_TEMPORAL_REUSE
    bool gTemporalHistoryValid;
    float3 gPreviousCameraPosition;
#endif
}

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
    float3 laserPrevOrigin;
    float3 laserPrevDirection;
#if IS_SCENE_DYNAMIC && USE_TEMPORAL_REUSE
    float3 laserPrevPower;
    float laserPrevCosAngle;
#endif
}


// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float2> gMotionVector; // Optional
#if USE_TEMPORAL_REUSE
Texture2D<PackedHitInfo> gTemporalVBuffer;
#endif


// Reservoir Struct
StructuredBuffer<Reservoir> prevReservoirs;
RWStructuredBuffer<Reservoir> currReservoirs;

// Outputs
RWTexture2D<float4> gOutputColor;
#if COMPUTE_DIRECT
// Primary-hit direct lighting (camera -> primary hit -> laser spot), kept out of the reservoirs; AddDirect.cs.slang
// adds it to the output after reuse.
RWTexture2D<float4> gDirectColor;
#endif

EmissiveLightSampler emissiveSampler;

static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;


#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
// A terminal ellipse branch inserts one surface, leaving the replayable BSDF walk
// and its RNG untouched. recordHit removes the ACTUAL proposal density at a->x
// or x->y; after y it instead stores cosine_y / ellipsePdf in the suffix payload.
void submitEllipsoidalCandidate(inout Reservoir reservoir, ReconnectionState rc,
    ShadingData origin, IMaterialInstance material, LightSample light, float prefixLength,
    float3 throughput, uint targetDepth, uint lightSeed, inout SampleGenerator rng)
{
    if (!light.valid) return;
    EllipsoidalSample ellipsoidal;
    if (!sampleEllipsoid(origin, prefixLength, light, tcurr, emissiveSampler, rng, ellipsoidal)) return;
    ShadingData target = ellipsoidal.surface;
    let targetMaterial = gScene.materials.getMaterialInstance(target, ExplicitLodTextureSampler(0.f));
    float targetLength = prefixLength + ellipsoidal.distance * origin.IoR;
    if (!(targetLength < getMaxpathLength(tcurr))) return;
    float techniqueWeight = 1.f;
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
    float bsdfPdf = material.evalPdf(origin, ellipsoidal.direction, kUseImportanceSampling);
    techniqueWeight = balanceWeight(ellipsoidal.pdf, bsdfPdf);
#endif
    BSDFSample proposal = {};
    proposal.wo = ellipsoidal.direction;
    proposal.pdf = ellipsoidal.pdf;
    proposal.weight = material.eval(origin, ellipsoidal.direction, rng) / ellipsoidal.pdf;
    bool eligible = material.getProperties(origin).roughness > specularRoughnessThreshold &&
        targetMaterial.getProperties(target).roughness > specularRoughnessThreshold;
    float suffixDirectionWeight = 0.f;
    if (rc.postBounce == 2) suffixDirectionWeight = shadingCosine(origin, material, ellipsoidal.direction) / ellipsoidal.pdf;
    rc.recordHit(ellipsoidal.hit, target, proposal, targetDepth, eligible, ellipsoidal.distance, origin.IoR,
        suffixDirectionWeight, 0);
    LightConnection connection = evaluateLightConnection(target, targetMaterial, light, rng);
    float totalLength = targetLength + connection.distance + light.laserT;
    float gate = pathLengthImportance(totalLength, tcurr);
    submitCandidate(reservoir, rc, target, targetMaterial, light, connection, totalLength, gate,
        throughput * proposal.weight, techniqueWeight, samplesPerPixel, lightSeed, false, rng);
}

#endif

#if USE_SHRINK_MAPPING
// Each input estimates its gate integral as W*f (before division by gate width).
// The existing shift helper supplies the mapped target, area Jacobian and
// complementary target-based MIS weights. Never put the MIS weight into f.
Reservoir mergeGateReservoirs(Reservoir narrow, Reservoir wide, uint narrowCount, uint wideCount,
    ShadingData primary, IMaterialInstance primaryMaterial, float primaryLength, inout SampleGenerator rng)
{
    float narrowTarget = getReservoirWeight(narrow.f);
    float wideTarget = getReservoirWeight(wide.f);
    narrow.W = narrowTarget > 0.f ? narrow.wSum / narrowTarget : 0.f;
    wide.W = wideTarget > 0.f ? wide.wSum / wideTarget : 0.f;
    // MIS uses actual path counts, not the number of light connections submitted
    // along those paths, nor the requested (possibly rounded) split ratio.
    narrow.M = float(narrowCount);
    wide.M = float(wideCount);
    const float K = time_gate_window / time_gate_window_rough;
    Reservoir merged = Reservoir();
#if DEBUG_NEWTON_ITERATIONS
    // Initial shrinking must not enter the spatial-neighbor diagnostic buffers.
    ShiftMappingDebugInfo debugInfo = {};
#endif
    // K is the narrow/wide gate-width ratio: L' = tcurr + K*(L-tcurr).
    combine_reservoir_with_shiftmapping(merged, wide, narrow.M, specularRoughnessThreshold,
        primary, primaryMaterial, primaryLength, tcurr, tcurr, K, false,
        laserOrigin, laserDirection, rng
#if DEBUG_NEWTON_ITERATIONS
        , debugInfo
#endif
    );
    // Expand the canonical narrow sample only to evaluate competing wide support.
    // A failed expansion or no-RC path retains the full narrow contribution.
    if (narrowCount > 0)
    {
        combine_reservoir_with_shiftmapping(merged, narrow, wide.M, specularRoughnessThreshold,
            primary, primaryMaterial, primaryLength, tcurr, tcurr, 1.f / K, true,
            laserOrigin, laserDirection, rng
#if DEBUG_NEWTON_ITERATIONS
            , debugInfo
#endif
        );
    }
    // The no-RC canonical branch in the shared helper copies only f and its flag.
    // Preserve the selected narrow path length as well (there is no wide no-RC candidate).
    if (merged.rcVertexBounce == 0) merged.totalPathLength = narrow.totalPathLength;
    float target = getReservoirWeight(merged.f);
    merged.W = target > 0.f ? merged.wSum / target : 0.f;
    return merged;
}
#endif

#if USE_TEMPORAL_REUSE
// Static mode keeps the suffix; dynamic mode evaluates each temporal direction
// with its target frame's light while retaining the source target for MIS.
Reservoir reuseTemporalHistory(Reservoir fresh, uint2 pixel, ShadingData primary,
    IMaterialInstance primaryMaterial, float primaryLength, inout SampleGenerator rng)
{
    // Use camera-path counts consistently, including paths with no contribution.
    fresh.M = float(samplesPerPixel);
    if (!gTemporalHistoryValid || gTemporalHistoryLength == 0.f) return fresh;

    float2 previousPosition = float2(pixel) + 0.5f;
#if is_valid_gMotionVector
    previousPosition += gMotionVector[pixel] * float2(gFrameDim);
#endif
    if (!all(isfinite(previousPosition)) || any(previousPosition < 0.f) ||
        any(previousPosition >= float2(gFrameDim))) return fresh;
    uint2 previousPixel = uint2(floor(previousPosition));
    HitInfo previousHit = HitInfo(gTemporalVBuffer[previousPixel]);
    if (!previousHit.isValid()) return fresh;
    float3 previousPoint = gScene.getVertexData(previousHit.getTriangleHit()).posW;
    float3 previousDirection = previousPoint - gPreviousCameraPosition;
    float previousLength = length(previousDirection);
    if (!(previousLength > 0.f)) return fresh;
    ShadingData previousPrimary = loadShadingData(previousHit, gPreviousCameraPosition,
        previousDirection / previousLength);
    let previousMaterial = gScene.materials.getMaterialInstance(previousPrimary, ExplicitLodTextureSampler(0.f));

#if IS_SCENE_DYNAMIC
    // Match the old temporal disocclusion test before assigning history any mass.
    // A valid previous hit can still belong to a different surface/material.
    if (primary.materialID != previousPrimary.materialID ||
        dot(primary.getOrientedFaceNormal(), previousPrimary.getOrientedFaceNormal()) <= 0.7f ||
        abs(primaryLength - previousLength) >= 0.1f * primaryLength)
        return fresh;
#endif

    Reservoir history = prevReservoirs[previousPixel.y * gFrameDim.x + previousPixel.x];
    if (gTemporalHistoryLength > 0.f)
        history.M = min(history.M, gTemporalHistoryLength * float(samplesPerPixel));
    if (!(history.M > 0.f)) return fresh;

    Reservoir merged = Reservoir();
#if DEBUG_NEWTON_ITERATIONS
    // Temporal mapping is excluded from the spatial-only diagnostic outputs.
    ShiftMappingDebugInfo debugInfo = {};
#endif
    // Previous -> current: source gate tprev, target gate tcurr.
    combine_reservoir_with_shiftmapping(merged, history, fresh.M, specularRoughnessThreshold,
        primary, primaryMaterial, primaryLength, tcurr, tprev, 1.f, false,
        laserOrigin, laserDirection, rng
#if DEBUG_NEWTON_ITERATIONS
        , debugInfo
#endif
#if IS_SCENE_DYNAMIC
        , true, laserPower, laserCosAngle
#endif
    );
    // Current -> previous evaluates competing support, retaining the current sample.
    combine_reservoir_with_shiftmapping(merged, fresh, history.M, specularRoughnessThreshold,
        previousPrimary, previousMaterial, previousLength, tprev, tcurr, 1.f, true,
#if IS_SCENE_DYNAMIC
        laserPrevOrigin, laserPrevDirection, rng
#else
        laserOrigin, laserDirection, rng
#endif
#if DEBUG_NEWTON_ITERATIONS
        , debugInfo
#endif
#if IS_SCENE_DYNAMIC
        , true, laserPrevPower, laserPrevCosAngle
#endif
    );
    if (merged.rcVertexBounce == 0) merged.totalPathLength = fresh.totalPathLength;
    float target = getReservoirWeight(merged.f);
    merged.W = target > 0.f ? merged.wSum / target : 0.f;
    return merged;
}
#endif

#if COMPUTE_DIRECT
// Direct lighting at the primary hit, divided by the gate width like the output. It uses its own random stream, so
// the reservoirs sample the same paths with and without it.
float3 evalPrimaryDirect(uint2 pixel, ShadingData primary, IMaterialInstance primaryMaterial, float primaryLength)
{
    LaserLightSampler lightSampler = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kDirectSampleStream);
    float3 direct = 0.f;
    for (uint i = 0; i < samplesPerPixel; ++i)
    {
        LightSample light = {};
        lightSampler.generateLightSample(sg, light);
        if (!light.valid) continue;
        LightConnection connection = evaluateLightConnection(primary, primaryMaterial, light, sg);
        float gate = pathLengthImportance(primaryLength + connection.distance + light.laserT, tcurr);
        direct += connection.bsdfCosine * connection.incidentRadiance * gate;
    }
    direct /= float(samplesPerPixel) * time_gate_window;
    if (any(isinf(direct) || isnan(direct))) direct = 0.f;
#if USE_SINGLE_CHANNEL
    direct = float3(selectChannel(direct));
#endif
    return direct;
}
#endif

// Generate initial RIS candidates by BSDF walking and connecting each secondary
// surface to the single point/laser light. Primary direct lighting stays out of the reservoirs
// (with computeDirect it is evaluated separately and added after reuse).
float3 tracePath(uint2 pixel, uint2 frameDim)
{
    uint index = pixel.y * frameDim.x + pixel.x;
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    float3 primaryDirection = getPrimaryRayDir(pixel, frameDim, gViewW);
    Reservoir reservoir = Reservoir();
    if (!primaryHit.isValid())
    {
#if COMPUTE_DIRECT
        gDirectColor[pixel] = float4(0.f);
#endif
        currReservoirs[index] = reservoir;
        return kUseEnvBackground ? gScene.envMap.eval(primaryDirection) : float3(0.f);
    }

    float3 cameraPosition = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraPosition, primaryDirection);
    let primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float primaryLength = length(primary.posW - cameraPosition);
#if COMPUTE_DIRECT
    gDirectColor[pixel] = float4(evalPrimaryDirect(pixel, primary, primaryMaterial, primaryLength), 0.f);
#endif
#if USE_SHRINK_MAPPING
    // The host enables shrink mapping only when this count is positive; ratio 1 uses only wide samples.
    const uint wideCount = min(uint(float(samplesPerPixel) * gRoughTimeGateSampleRatio), samplesPerPixel);
    const uint narrowCount = samplesPerPixel - wideCount;
    Reservoir wideReservoir = Reservoir();
    const float wideSampleWeight = float(samplesPerPixel) / float(wideCount);
    const float narrowSampleWeight = narrowCount > 0 ? float(samplesPerPixel) / float(narrowCount) : 0.f;
#else
    float maxPathLength = getMaxpathLength(tcurr);
#endif
    LaserLightSampler lightSampler = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);
    // Preserve separate streams so prefix replay never consumes reservoir/light RNG draws.
    SampleGenerator rng = createPixelSampleGenerator(pixel, gFrameCount, kReservoirSampleStream);
    SampleGenerator bsdfRng = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);
    SampleGenerator lightRng = createPixelSampleGenerator(pixel, gFrameCount, kLightSampleStream);

    for (uint sampleIndex = 0; sampleIndex < samplesPerPixel; ++sampleIndex)
    {
        bool useRoughGate = false;
#if USE_SHRINK_MAPPING
        useRoughGate = sampleIndex >= narrowCount;
        float maxPathLength = getMaxpathLength(tcurr, useRoughGate);
#endif
        ShadingData surface = primary;
        IMaterialInstance material = primaryMaterial;
        float3 throughput = 1.f;
        float pathLength = primaryLength;
        ReconnectionState rc = {};
        rc.xHit = makeInvalidHit();
        rc.yHit = makeInvalidHit();
        rc.areaPdf = 1.f;
        rc.suffixThroughput = 1.f;
        rc.prefixSeed = bsdfRng.getCurrentSeed();

        for (uint depth = 1; depth < MAX_BOUNCES; ++depth)
        {
            if (!any(throughput > 0.f)) break;
            if (!(pathLength < maxPathLength)) break;
#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
            ScatterRecord previous = {};
            previous.posW = surface.posW;
            previous.normalW = surface.getOrientedFaceNormal();
            previous.pathLength = pathLength;
            previous.ellipsoidEligible = (material.getLobeTypes(surface) & uint(LobeType::NonDelta)) != 0;
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
            previous.ellipsoidEligible = previous.ellipsoidEligible &&
                material.getProperties(surface).roughness > specularRoughnessThresholdEllipsoid;
#endif
            if (previous.ellipsoidEligible)
            {
                LightSample ellipseLight = {};
                uint ellipseLightSeed = lightRng.getCurrentSeed();
                lightSampler.generateLightSample(lightRng, ellipseLight);
                submitEllipsoidalCandidate(reservoir, rc, surface, material, ellipseLight,
                    pathLength, throughput, depth, ellipseLightSeed, rng);
            }
#endif
            bool previousDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            uint sampleSeed = bsdfRng.getCurrentSeed();
            BSDFSample sample = {};
            if (!material.sample(surface, bsdfRng, sample, kUseImportanceSampling)) break;
#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
            previous.bsdfPdf = sample.pdf;
            previous.isDelta = sample.isLobe(LobeType::Delta);
#endif
            throughput *= sample.weight;
            if (!any(throughput > 0.f)) break;

            // Capture at y before replacing its shading state with the hit at z.
            float suffixDirectionWeight = 0.f;
            if (rc.postBounce == 2)
            {
                if (sample.pdf > 0.f)
                    suffixDirectionWeight = shadingCosine(surface, material, sample.wo) / sample.pdf;
            }
            float3 previousPosition = surface.posW;
            float segmentIoR = surface.IoR;
            float3 origin = surface.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
            SceneRayQuery<USE_ALPHA_TEST> query;
            float hitT;
            HitInfo hit = query.traceRay(Ray(origin, sample.wo, 0.f, FLT_MAX), hitT);
            if (!hit.isValid()) break;
            surface = loadShadingData(hit, origin, sample.wo);
            material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            float segmentLength = length(surface.posW - previousPosition);
            pathLength += segmentLength * segmentIoR;
            if (!(pathLength < maxPathLength)) break;
            bool currentDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            rc.recordHit(hit, surface, sample, depth, previousDiffuse && currentDiffuse && segmentLength > 0.f,
                segmentLength, segmentIoR, suffixDirectionWeight, sampleSeed);

            LightSample light = {};
            uint lightSeed = lightRng.getCurrentSeed();
            lightSampler.generateLightSample(lightRng, light);
            LightConnection connection = evaluateLightConnection(surface, material, light, rng);
            float totalLength = pathLength + connection.distance + light.laserT;
            float gate = pathLengthImportance(totalLength, tcurr, useRoughGate);
            float techniqueWeight = 1.f;
#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
            techniqueWeight = evalBsdfTechniqueWeight(previous, surface, hit, light, tcurr, emissiveSampler,
                LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS);
#endif
#if USE_SHRINK_MAPPING
            // submitCandidate divides by samplesPerPixel. Correct that to 1/N_i
            // so each gate reservoir separately estimates its full gate integral.
            if (useRoughGate)
                submitCandidate(wideReservoir, rc, surface, material, light, connection, totalLength, gate,
                    throughput, wideSampleWeight, samplesPerPixel, lightSeed, false, rng);
            else
                submitCandidate(reservoir, rc, surface, material, light, connection, totalLength, gate,
                    throughput, narrowSampleWeight, samplesPerPixel, lightSeed, false, rng);
#else
            submitCandidate(reservoir, rc, surface, material, light, connection, totalLength, gate,
                throughput, techniqueWeight, samplesPerPixel, lightSeed, false, rng);
#endif
            if (rc.bounce > 0) ++rc.postBounce;
        }
    }
#if USE_SHRINK_MAPPING
    reservoir = mergeGateReservoirs(reservoir, wideReservoir, narrowCount, wideCount,
        primary, primaryMaterial, primaryLength, rng);
#endif
    float target = getReservoirWeight(reservoir.f);
    reservoir.W = target > 0.f ? reservoir.wSum / target : 0.f;
#if USE_TEMPORAL_REUSE
    reservoir = reuseTemporalHistory(reservoir, pixel, primary, primaryMaterial, primaryLength, rng);
#endif
    currReservoirs[index] = reservoir;
    return float3(reservoir.W * reservoir.f); // with a scalar target, the kept channel in all three
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] = float4(tracePath(pixel, gFrameDim) / time_gate_window, 1.f);
}
