#include "RenderPasses/TransientHistogramReSTIRInline/HistogramReSTIRCommon.slangh"

// Two-pass temporal reuse (TEMPORAL_REUSE_PAIRS), first pass, per chunk of bins [gPairFirstBin, gPairFirstBin +
// gPairBinCount): both sides of each bin's merge with the history (mergeReservoirPair with K = 1), one thread per pixel
// and bin, into a ReusePair for TemporalReuse.cs.slang. The shifts draw no random numbers.

[numthreads(32, 2, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return;
    TemporalHistory history = getTemporalHistory(pixel);
    if (!history.valid) return;
    uint bin = gPairFirstBin + dispatchThreadId.z;
    uint pixelIndex = pixel.y * gFrameDim.x + pixel.x;
    uint index = pixelIndex * gTimeBin + bin;
    uint previousIndex = history.pixelIndex * gTimeBin + bin;
    float2 previousSummary = getPrevSummary(previousIndex);
    float historyMass = getHistoryMass(previousSummary);
    if (!(historyMass > 0.f) || isEmptyTemporalPair(getCurrSummary(index), previousSummary)) return;

    Reservoir current = loadCurrReservoir(index);
    Reservoir previous = loadPrevReservoir(previousIndex);
    previous.M = historyMass;
    float3 cameraPosition = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraPosition, getPrimaryRayDir(pixel, gFrameDim, gViewW));
    let primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float primaryLength = length(primary.posW - cameraPosition);
    let previousMaterial = gScene.materials.getMaterialInstance(history.primary, ExplicitLodTextureSampler(0.f));
    float gateCenter = binCenter(bin);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kTemporalReuseStream);
    ShiftMappingDebugInfo debugInfo = {};
    // History -> current, and current -> history for the canonical sample's weight.
    IncomingCandidate incoming = evaluateIncomingCandidate(previous, current.M, getReconnectionCriteria(), primary,
        primaryMaterial, primaryLength, gateCenter, gateCenter, 1.f, gLaserOrigin, gLaserDirection, sg, debugInfo);
    CanonicalCandidate canonical = evaluateCanonicalCandidate(current, previous.M, getReconnectionCriteria(),
        history.primary, previousMaterial, history.primaryLength, gateCenter, gateCenter, 1.f, gLaserOrigin,
        gLaserDirection, sg, debugInfo);

    ReusePair pair;
    pair.hit = incoming.hit;
    pair.f = incoming.f;
    pair.weight = incoming.weight;
    pair.prefixEnd = incoming.prefixEnd;
    pair.totalPathLength = incoming.totalPathLength;
    pair.canonical = canonical.weight;
    pair.sourceM = previous.M;
    pair.status = incoming.kind | (canonical.kind << 8);
    gTemporalPairs[getTemporalPairIndex(pixelIndex, bin)] = pair;
}
