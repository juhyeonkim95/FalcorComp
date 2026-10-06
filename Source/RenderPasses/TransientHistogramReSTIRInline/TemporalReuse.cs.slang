#include "RenderPasses/TransientHistogramReSTIRInline/HistogramReSTIRCommon.slangh"

// Two-pass temporal reuse (TEMPORAL_REUSE_PAIRS), second pass, per chunk of bins: streams the ReusePairs of
// TemporalReusePairs.cs.slang into each pixel's reservoirs in bin order, continuing the random state that initial
// generation left in gTemporalRandomState, as the single-kernel merge of InitialSampleGeneration.cs.slang does. A pixel
// without history keeps the outputs of initial generation.

// mergeReservoirPair of `current` with the history reservoir at previousIndex (mass historyMass) from its pair record.
Reservoir mergeTemporalPair(Reservoir current, ReservoirIndex previousIndex, float historyMass, uint pairIndex,
    inout SampleGenerator rng)
{
    Reservoir previous = loadPrevReservoir(previousIndex);
    previous.M = historyMass;
    IncomingCandidate incoming = {};
    incoming.kind = kIncomingMassOnly;
    CanonicalCandidate canonical = {};
    canonical.kind = kCanonicalMassOnly;
    if (!isEmptyTemporalPair(float2(current.W, current.M), float2(previous.W, previous.M)))
    {
        ReusePair pair = gTemporalPairs[pairIndex];
        incoming.hit = pair.hit;
        incoming.f = pair.f;
        incoming.weight = pair.weight;
        incoming.prefixEnd = pair.prefixEnd;
        incoming.totalPathLength = pair.totalPathLength;
        incoming.kind = pair.status & 0xff;
        canonical.weight = pair.canonical;
        canonical.kind = pair.status >> 8;
    }
    Reservoir merged = Reservoir();
    streamIncomingCandidate(merged, incoming, previous, rng);
    streamCanonicalCandidate(merged, canonical, current, rng);
    // The canonical no-RC branch copies only f and its flag; keep the selected length too.
    if (merged.rcVertexBounce == 0) merged.totalPathLength = current.totalPathLength;
    merged.finalizeW();
    return merged;
}

[numthreads(8, 4, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    uint pixelIndex = pixel.y * gFrameDim.x + pixel.x;
    // Initial generation found the history (none without a primary hit).
    uint historyPixel = gTemporalHistoryPixel[pixelIndex];
    if (historyPixel == kNoHistory) return;
    SampleGenerator rng = SampleGenerator(gTemporalRandomState[pixelIndex]);
    float3 integratedRadiance = gPairFirstBin == 0 ? float3(0.f) : gOutputColor[pixel].xyz;
    for (uint bin = gPairFirstBin; bin < gPairFirstBin + gPairBinCount; ++bin)
    {
        ReservoirIndex index = reservoirIndex(pixelIndex, bin);
        ReservoirIndex previousIndex = reservoirIndex(historyPixel, bin);
        Reservoir reservoir = loadCurrReservoir(index);
        float historyMass = getHistoryMass(getPrevSummary(previousIndex));
        if (historyMass > 0.f)
        {
            reservoir = mergeTemporalPair(reservoir, previousIndex, historyMass, getTemporalPairIndex(pixelIndex, bin),
                rng);
            storeReservoir(index, reservoir);
        }
        float3 radiance = reservoir.W * reservoir.f;
        integratedRadiance += radiance;
        if (gWriteHistogram) gTransientHistogram[uint3(pixel, bin)] = toHistogramTexel(radiance / gBinWidth);
    }
    gTemporalRandomState[pixelIndex] = rng.getCurrentSeed();
    gOutputColor[pixel] = float4(integratedRadiance, 1.f);
}
