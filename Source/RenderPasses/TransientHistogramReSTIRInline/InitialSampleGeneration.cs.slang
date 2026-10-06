#include "RenderPasses/TransientHistogramReSTIRInline/HistogramReSTIRCommon.slangh"

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
        // Selection needs only wSum: the stored reservoir is rewritten only if the candidate is selected. M is set at
        // finalization, and a selection sets every field in use.
        Reservoir reservoir = Reservoir();
        const float previousWeightSum = touched.inMemory(bin) ? gCurrReservoirs[index].wSum : 0.f;
        reservoir.wSum = previousWeightSum;
        if (submitCandidate(reservoir, rc, surface, material, light, connection, totalLength, gate,
                throughput, 1.f, gSamplesPerPixel, lightSeed, true, rng))
            gCurrReservoirs[index] = reservoir;
        else if (reservoir.wSum != previousWeightSum)
            gCurrReservoirs[index].wSum = reservoir.wSum;
        else
            continue; // Rejected: nothing to store.
        touched.add(bin);
    }
}

float3 tracePath(uint2 pixel, uint2 frameDim)
{
    uint pixelIndex = pixel.y * frameDim.x + pixel.x;
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid())
    {
#if TEMPORAL_REUSE_PAIRS
        gTemporalHistoryPixel[pixelIndex] = kNoHistory;
#endif
        for (uint bin = 0; bin < gTimeBin; ++bin)
        {
            storeReservoir(pixelIndex * gTimeBin + bin, Reservoir());
            gTransientHistogram[uint3(pixel, bin)] = 0.f;
        }
        return 0.f;
    }
    // The finalization below stores every bin's reservoir (storeReservoir) and histogram texel; only bins past the mask
    // need a clear, for candidate submission.
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
            if (depth > 0 || COMPUTE_DIRECT != 0)
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

            bool previousDiffuse = gReconnection.isRough(material.getProperties(surface).roughness);
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
            bool currentDiffuse = gReconnection.isRough(material.getProperties(surface).roughness);
            rc.recordHit(hit, surface, previousPosition, sample, depth + 1,
                previousDiffuse && currentDiffuse && gReconnection.isLongEnough(segmentLength),
                segmentLength, segmentIoR, suffixDirectionWeight, sampleSeed);
        }
    }

#if USE_TEMPORAL_REUSE && !TEMPORAL_REUSE_PAIRS
    TemporalHistory history = getTemporalHistory(pixel);
    IMaterialInstance previousMaterial = primaryMaterial;
    if (history.valid)
        previousMaterial = gScene.materials.getMaterialInstance(history.primary, ExplicitLodTextureSampler(0.f));
#elif TEMPORAL_REUSE_PAIRS
    // Found once here for the temporal kernels, which run one thread per pixel and bin.
    {
        TemporalHistory history = getTemporalHistory(pixel);
        gTemporalHistoryPixel[pixelIndex] = history.valid ? history.pixelIndex : kNoHistory;
    }
#endif

    float3 integratedRadiance = 0.f;
    for (uint bin = 0; bin < gTimeBin; ++bin)
    {
        uint index = pixelIndex * gTimeBin + bin;
        Reservoir reservoir = touched.inMemory(bin) ? gCurrReservoirs[index] : Reservoir();
        reservoir.finalizeW();
        // Each bin had gSamplesPerPixel path trials, including paths contributing zero.
        reservoir.M = gSamplesPerPixel;
#if USE_TEMPORAL_REUSE && !TEMPORAL_REUSE_PAIRS
        if (history.valid)
        {
            Reservoir previous = loadPrevReservoir(history.pixelIndex * gTimeBin + bin);
            previous.M = temporalHistoryMass(previous.M, gTemporalHistoryLength, gSamplesPerPixel);
            if (previous.M > 0.f)
            {
                float gateCenter = binCenter(bin);
                ReuseDomain current = { primary, primaryMaterial, primaryLength, gateCenter, gLaserOrigin,
                    gLaserDirection, gLaserPower, gLaserCosAngle };
                ReuseDomain last = { history.primary, previousMaterial, history.primaryLength, gateCenter, gLaserOrigin,
                    gLaserDirection, gLaserPower, gLaserCosAngle };
                reservoir = mergeReservoirPair(reservoir, current, previous, last, 1.f, false,
                    gReconnection, rng);
            }
        }
#endif
        storeReservoir(index, reservoir);
        float3 radiance = reservoir.W * reservoir.f;
        integratedRadiance += radiance;
        gTransientHistogram[uint3(pixel, bin)] = toHistogramTexel(radiance / gBinWidth);
    }
#if TEMPORAL_REUSE_PAIRS
    // The merges (TemporalReuse.cs.slang) draw next.
    gTemporalRandomState[pixelIndex] = rng.getCurrentSeed();
#endif
    return integratedRadiance;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] = float4(tracePath(pixel, gFrameDim), 1.f);
}
