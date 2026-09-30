#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import RenderPasses.Shared.Shaders.Utils.TimeGate;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.ReSTIR.Reservoirs;

import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.ReSTIR.PathReconstruction;
import RenderPasses.Shared.Shaders.ReSTIR.InitialCandidates;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
#if USE_TEMPORAL_REUSE
import RenderPasses.Shared.Shaders.ReSTIR.ReservoirReuse;
import RenderPasses.Shared.Shaders.ReSTIR.TemporalReuse;
#endif
import RenderPasses.Shared.Shaders.Lights.Laser;


cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    
    uint gSamplesPerPixel;
    float gReconnectionRoughnessThreshold;
    float gReconnectionMinDistance;
    float gTemporalHistoryLength;
#if USE_TEMPORAL_REUSE
    bool gTemporalHistoryValid;
    float3 gPreviousCameraPosition;
#endif
}


ReconnectionCriteria getReconnectionCriteria()
{
    ReconnectionCriteria criteria = { gReconnectionRoughnessThreshold, gReconnectionMinDistance };
    return criteria;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float2> gMotionVector; // Optional
#if USE_TEMPORAL_REUSE
Texture2D<PackedHitInfo> gTemporalVBuffer;
#endif


// Reservoir Struct
StructuredBuffer<Reservoir> gPrevReservoirs; // Last frame's final reservoirs (temporal reuse).
RWStructuredBuffer<Reservoir> gCurrReservoirs;
// W and M of each reservoir: only reservoirs with W != 0 are stored after finalization (loadSummarizedReservoir).
StructuredBuffer<float2> gPrevSummaries;
RWStructuredBuffer<float2> gCurrSummaries;

// Outputs
RWTexture2D<float4> gOutputColor;

RWTexture3D<HistogramTexel> gTransientHistogram;


// TimeGateMode::Box; macros in imported Slang modules are not exported.
static const uint kTimeGateBox = 1;


// Which of the first 64 bins of a pixel have received a candidate this frame, so that their reservoirs are in memory.
// The other bins start as empty reservoirs in registers instead of being cleared in memory first (most bins never get a
// candidate); bins from 64 on are still cleared up front.
struct TouchedBins
{
    uint2 bits;

    bool inMemory(uint bin) { return bin >= 64 || ((bits[bin >> 5] >> (bin & 31)) & 1) != 0; }

    [mutating]
    void add(uint bin)
    {
        if (bin < 64) bits[bin >> 5] |= 1u << (bin & 31);
    }
};

// The same completed path is a candidate for every gate it overlaps.
// Box bins are disjoint, so that common case updates only one reservoir.
void submitHistogramCandidate(uint pixelIndex, ReconnectionState rc, ShadingData surface,
    IMaterialInstance material, LightSample light, LightConnection connection,
    float totalLength, float3 throughput, uint lightSeed, inout TouchedBins touched, inout SampleGenerator rng)
{
    uint firstBin = 0;
    uint endBin = gTimeBin;
    if (gTimeGateMode == kTimeGateBox)
    {
        if (!(totalLength >= gTimeMin && totalLength < gTimeMax)) return;
        firstBin = min(uint((totalLength - gTimeMin) / gBinWidth), gTimeBin - 1);
        endBin = firstBin + 1;
    }
    for (uint bin = firstBin; bin < endBin; ++bin)
    {
        float center = binCenter(bin);
        // Half-open box bins assign boundary samples exactly once.
        float gate = gTimeGateMode == kTimeGateBox ? 1.f : pathLengthImportance(totalLength, center);
        if (!(gate > 0.f)) continue;
        uint index = pixelIndex * gTimeBin + bin;
        Reservoir reservoir = touched.inMemory(bin) ? gCurrReservoirs[index] : Reservoir();
        submitCandidate(reservoir, rc, surface, material, light, connection, totalLength, gate,
            throughput, 1.f, gSamplesPerPixel, lightSeed, true, rng);
        gCurrReservoirs[index] = reservoir;
        touched.add(bin);
    }
}

float3 tracePath(uint2 pixel, uint2 frameDim)
{
    uint pixelIndex = pixel.y * frameDim.x + pixel.x;
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid())
    {
        for (uint bin = 0; bin < gTimeBin; ++bin)
        {
            storeSummarizedReservoir(gCurrReservoirs, gCurrSummaries, pixelIndex * gTimeBin + bin, Reservoir());
            gTransientHistogram[uint3(pixel, bin)] = 0.f;
        }
        return 0.f;
    }
    // The finalization below stores every bin (its summary, and its reservoir if not empty) and histogram texel; only
    // bins past the mask need a clear, for candidate submission.
    TouchedBins touched = {};
    for (uint bin = 64; bin < gTimeBin; ++bin)
        gCurrReservoirs[pixelIndex * gTimeBin + bin] = Reservoir();

    float3 cameraPosition = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraPosition, getPrimaryRayDir(pixel, frameDim, gViewW));
    let primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float primaryLength = length(primary.posW - cameraPosition);
    float maxPathLength = getMaxPathLength(binCenter(gTimeBin - 1));
    LaserLightSampler lightSampler = createLaserLightSampler();
    // Prefix replay must not consume light or reservoir RNG draws.
    SampleGenerator rng = createPixelSampleGenerator(pixel, gFrameCount, kReservoirSampleStream);
    SampleGenerator bsdfRng = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);
    SampleGenerator lightRng = createPixelSampleGenerator(pixel, gFrameCount, kLightSampleStream);

    for (uint sampleIndex = 0; sampleIndex < gSamplesPerPixel; ++sampleIndex)
    {
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

        // Match the histogram PT convention: primary = depth zero.
        for (uint depth = 0; depth < max(1u, uint(MAX_BOUNCES)) &&
            pathLength < maxPathLength && any(throughput > 0.f); ++depth)
        {
            if (depth > 0 || COMPUTE_DIRECT)
            {
                LightSample light = {};
                uint lightSeed = lightRng.getCurrentSeed();
                lightSampler.generateLightSample(lightRng, light);
                bool connected;
                LightConnection connection = connectToLight(surface, light, connected);
                float totalLength = pathLength + connection.distance + light.laserT;
                // Box bins drop candidates outside [gTimeMin, gTimeMax) unevaluated: skip their visibility ray and
                // BSDF evaluation.
                bool inRange = gTimeGateMode != kTimeGateBox || (totalLength >= gTimeMin && totalLength < gTimeMax);
                if (connected && inRange) shadeLightConnection(connection, surface, material, light, rng);
                submitHistogramCandidate(pixelIndex, rc, surface, material, light, connection, totalLength,
                    throughput, lightSeed, touched, rng);
            }
            if (rc.bounce > 0) ++rc.postBounce;
            if (depth + 1 >= MAX_BOUNCES) break;

            bool previousDiffuse = material.getProperties(surface).roughness > gReconnectionRoughnessThreshold;
            uint sampleSeed = bsdfRng.getCurrentSeed();
            BSDFSample sample = {};
            if (!material.sample(surface, bsdfRng, sample, USE_IMPORTANCE_SAMPLING)) break;
            throughput *= sample.weight;
            float suffixDirectionWeight = 0.f;
            if (rc.postBounce == 2 && sample.pdf > 0.f)
                suffixDirectionWeight = shadingCosine(surface, material, sample.wo) / sample.pdf;

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
            // Match time-gated generation and shared prefix replay.
            pathLength += segmentLength * segmentIoR;
            bool currentDiffuse = material.getProperties(surface).roughness > gReconnectionRoughnessThreshold;
            rc.recordHit(hit, surface, previousPosition, sample, depth + 1,
                previousDiffuse && currentDiffuse && segmentLength > gReconnectionMinDistance,
                segmentLength, segmentIoR, suffixDirectionWeight, sampleSeed);
        }
    }

#if USE_TEMPORAL_REUSE
    // Geometry and the light are static, so only the camera (and hence the camera prefix) differs between frames.
    // The gate center of a bin is the same in both frames.
    TemporalHistory history = {};
    if (gTemporalHistoryValid && gTemporalHistoryLength != 0.f)
        history = findTemporalHistory(pixel, frameDim, gMotionVector, gTemporalVBuffer, gPreviousCameraPosition);
    IMaterialInstance previousMaterial = primaryMaterial;
    if (history.valid)
        previousMaterial = gScene.materials.getMaterialInstance(history.primary, ExplicitLodTextureSampler(0.f));
#endif

    float3 integratedRadiance = 0.f;
    for (uint bin = 0; bin < gTimeBin; ++bin)
    {
        uint index = pixelIndex * gTimeBin + bin;
        Reservoir reservoir = touched.inMemory(bin) ? gCurrReservoirs[index] : Reservoir();
        reservoir.finalizeW();
        // Each bin had gSamplesPerPixel path trials, including paths contributing zero.
        reservoir.M = gSamplesPerPixel;
#if USE_TEMPORAL_REUSE
        if (history.valid)
        {
            Reservoir previous = loadSummarizedReservoir(gPrevReservoirs, gPrevSummaries, history.pixelIndex * gTimeBin + bin);
            previous.M = temporalHistoryMass(previous.M, gTemporalHistoryLength, gSamplesPerPixel);
            if (previous.M > 0.f)
            {
                float gateCenter = binCenter(bin);
                ReuseDomain current = { primary, primaryMaterial, primaryLength, gateCenter, gLaserOrigin,
                    gLaserDirection, gLaserPower, gLaserCosAngle };
                ReuseDomain last = { history.primary, previousMaterial, history.primaryLength, gateCenter, gLaserOrigin,
                    gLaserDirection, gLaserPower, gLaserCosAngle };
                reservoir = mergeReservoirPair(reservoir, current, previous, last, 1.f, false,
                    getReconnectionCriteria(), rng);
            }
        }
#endif
        storeSummarizedReservoir(gCurrReservoirs, gCurrSummaries, index, reservoir);
        float3 radiance = reservoir.W * reservoir.f;
        integratedRadiance += radiance;
        gTransientHistogram[uint3(pixel, bin)] = toHistogramTexel(radiance / gBinWidth);
    }
    return integratedRadiance;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] = float4(tracePath(pixel, gFrameDim), 1.f);
}
