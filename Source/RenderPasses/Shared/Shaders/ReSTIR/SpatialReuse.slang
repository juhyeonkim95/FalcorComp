// Spatial reuse shared by the time-gated and histogram ReSTIR passes.
// Reservoirs are stored as [pixel * binCount + bin]; a time-gated pass is the
// single-bin case (binCount = 1, bin = 0, gateCenter = gTimeCenter).
// With useBinReuse, the adjacent bins (bin - 1, bin + 1) of the same pixel are
// additional candidates in the same pairwise MIS as the spatial neighbors. Their
// paths are shifted by one bin width with the path-length-aware shift mapping.
//
// resampleGate does one reservoir's whole reuse in one thread. With SPATIAL_REUSE_PAIRS, a reuse iteration is two
// passes instead (per chunk of bins): evaluatePair computes one candidate's shifts at one bin per thread (the central
// sample's canonical shift against it and its incoming shift) into a SpatialReusePair, and resampleFromPairs streams
// those records into each reservoir with the same random draws. A thread then holds one candidate rather than the
// whole neighbor loop, which keeps the shifts' register use from limiting the kernel's occupancy.
import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.TimeGate;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import RenderPasses.Shared.Shaders.ReSTIR.Reservoirs;
import RenderPasses.Shared.Shaders.ReSTIR.PathReconstruction;
import RenderPasses.Shared.Shaders.ReSTIR.ReservoirReuse;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.ShiftMapping.ShiftMapping;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import RenderPasses.Shared.Shaders.Lights.Laser;

// One reuse candidate of a reservoir (SPATIAL_REUSE_PAIRS): the incoming shift of the candidate's sample (an
// IncomingCandidate, with the candidate reservoir's M) and the canonical pairwise coefficient of the central sample
// against the candidate. 64 bytes. Only valid, non-empty pairs (isEmptyPair) have a record.
struct SpatialReusePair
{
    HitInfo hit;
    float3 f;
    float weight;
    float3 prefixEnd;
    float totalPathLength;
    float canonical;
    float sourceM;
    uint status; // IncomingCandidate kind (kIncomingMassOnly, kIncomingSample).
};

struct SpatialReuse
{
    static const uint kNeighborOffsetCount = NEIGHBOR_OFFSET_COUNT;
    static const uint kNeighborOffsetMask = kNeighborOffsetCount - 1;
    static const float kNormalThreshold = 0.7f;
    static const float kDepthThreshold = 0.1f;

    Texture1D<float2> neighborOffsets;
    uint neighborCount;
    float reconnectionRoughnessThreshold;
    float reconnectionMinDistance;
    float gatherRadius;
    bool useBinReuse; // Histogram only: bin centers are binCenter(bin).

    uint gFrameCount;
    uint gRandomSeed;
    uint2 gFrameDim;

    // Keep shader interface fields in sync with the C++ resource bindings.
    Texture2D<PackedHitInfo> gVBuffer;
    Texture2D<float4> gViewW;
    Texture2D<float2> gMotionVector; // Optional

    StructuredBuffer<Reservoir> prevReservoirs;
    RWStructuredBuffer<Reservoir> currReservoirs;
    RWTexture2D<float4> gOutputColor;
#if DEBUG_NEWTON_ITERATIONS
    RWTexture2D<uint4> gNewtonStatistics;
    RWTexture2D<float2> gMappingDistance;
#endif
#if SPATIAL_REUSE_PAIRS
    // Records of the bins [pairFirstBin, pairFirstBin + pairBinCount) (a chunk; a time gate has the single bin 0),
    // getMaxCandidateCount() per pixel and bin, ordered candidate, bin, pixel: the threads of a warp (neighboring
    // pixels, same candidate) access consecutive records.
    RWStructuredBuffer<SpatialReusePair> pairs;
    // Whether each spatial neighbor (neighborCount per pixel, ordered candidate, pixel) is a candidate; it does not
    // depend on the bin, so evaluatePair records it at the chunk's first bin.
    RWStructuredBuffer<uint> pairCandidateValid;
    uint pairFirstBin;
    uint pairBinCount;
#endif

    ReconnectionCriteria getReconnectionCriteria()
    {
        ReconnectionCriteria criteria = { reconnectionRoughnessThreshold, reconnectionMinDistance };
        return criteria;
    }

    uint getLinearizedPixel(uint2 pixel)
    {
        return pixel.y * gFrameDim.x + pixel.x;
    }

    int2 getNextNeighborPixel(uint startIndex, int2 pixel, uint index)
    {
        uint offsetIndex = (startIndex + index) & kNeighborOffsetMask;
        return pixel + int2(neighborOffsets[offsetIndex] * gatherRadius);
    }

    bool isValidScreenRegion(int2 pixel)
    {
        return all(pixel >= 0 && pixel < gFrameDim);
    }

    bool isValidGeometry(ShadingData center, ShadingData neighbor, float centerDepth, float neighborDepth)
    {
        return dot(center.getOrientedFaceNormal(), neighbor.getOrientedFaceNormal()) > kNormalThreshold
            && abs(centerDepth - neighborDepth) < kDepthThreshold * centerDepth;
    }

    // Adjacent bins that exist: bin - 1 first, then bin + 1.
    uint getAdjacentBinCount(uint binCount, uint bin)
    {
        if (!useBinReuse) return 0;
        return uint(bin > 0) + uint(bin + 1 < binCount);
    }

    uint getAdjacentBin(uint bin, uint index)
    {
        return (index == 0 && bin > 0) ? bin - 1 : bin + 1;
    }

    // update() already copies f and accumulates wSum/M. Copy only the selected path payload.
    void copySelectedPath(inout Reservoir destination, Reservoir source)
    {
        copyReconnectionPayload(destination, source);
        destination.rcVertexHit = source.rcVertexHit;
        destination.totalPathLength = source.totalPathLength;
    }

    uint getCandidateCount(uint binCount, uint bin)
    {
        return neighborCount + getAdjacentBinCount(binCount, bin);
    }

    uint getMaxCandidateCount()
    {
        return neighborCount + (useBinReuse ? 2 : 0);
    }

    // Pixel and bin of candidate i: the spatial neighbor startIndex + i at the same bin, or, past neighborCount,
    // this pixel at an adjacent bin.
    void getCandidate(uint2 pixel, uint bin, uint startIndex, uint i, out int2 neighborPixel, out uint neighborBin)
    {
        neighborPixel = int2(pixel);
        neighborBin = bin;
        if (i < neighborCount)
            neighborPixel = getNextNeighborPixel(startIndex, pixel, i);
        else
            neighborBin = getAdjacentBin(bin, i - neighborCount);
    }

    // Candidate i and its primary hit; false if it is not a candidate (outside the screen, this pixel, no hit, or
    // dissimilar geometry). An adjacent bin keeps this pixel's primary hit.
    bool selectCandidate(uint2 pixel, uint bin, float gateCenter, uint startIndex, uint i, ShadingData primary,
        IMaterialInstance primaryMaterial, float primaryDepth, float3 cameraOrigin, out int2 neighborPixel,
        out uint neighborBin, out float neighborGateCenter, out ShadingData neighborPrimary,
        out IMaterialInstance neighborMaterial, out float neighborDepth)
    {
        getCandidate(pixel, bin, startIndex, i, neighborPixel, neighborBin);
        neighborGateCenter = gateCenter;
        neighborPrimary = primary;
        neighborMaterial = primaryMaterial;
        neighborDepth = primaryDepth;
        if (i < neighborCount)
        {
            if (!isValidScreenRegion(neighborPixel)) return false;
            // Integer offsets may select this pixel, particularly at radius zero.
            if (all(neighborPixel == int2(pixel))) return false;

            HitInfo neighborHit = HitInfo(gVBuffer[neighborPixel]);
            if (!neighborHit.isValid()) return false;
            neighborPrimary = loadShadingData(neighborHit, cameraOrigin, getPrimaryRayDir(uint2(neighborPixel), gFrameDim, gViewW));
            neighborDepth = length(neighborPrimary.posW - cameraOrigin);
            if (!isValidGeometry(primary, neighborPrimary, primaryDepth, neighborDepth)) return false;
            neighborMaterial = gScene.materials.getMaterialInstance(neighborPrimary, ExplicitLodTextureSampler(0.f));
        }
        else
            neighborGateCenter = binCenter(neighborBin);
        return true;
    }

    // Add the unshifted central sample after all candidates (preserving the random draws' order), normalize, and
    // store the reservoir. centralReservoir.M is its split mass. Returns W * f.
    float3 finishReservoir(uint reservoirIndex, inout Reservoir destination, Reservoir centralReservoir,
        float canonicalWeight, uint candidateCount, uint validNeighborCount, inout SampleGenerator sg)
    {
        float centralTarget = getReservoirWeight(centralReservoir.f);
        float centralWeight = canonicalWeight * centralTarget * centralReservoir.W;
        centralReservoir.M *= candidateCount;
        if (destination.update(centralReservoir.f, centralWeight, centralReservoir.M, sg))
            copySelectedPath(destination, centralReservoir);

        destination.finalizeW();
        destination.W /= validNeighborCount + 1;
        currReservoirs[reservoirIndex] = destination;

        float3 color = float3(destination.W * destination.f);
        if (any(isinf(color) || isnan(color))) color = 0.f;
        return color;
    }

    // Resample the reservoir of one gate (bin) and store it in currReservoirs.
    // Returns W * f, the gate integral before division by the gate width.
    float3 resampleGate(uint2 pixel, uint binCount, uint bin, float gateCenter
#if DEBUG_NEWTON_ITERATIONS
        , out uint4 newtonStats, out float2 mappingDistance
#endif
    )
    {
#if DEBUG_NEWTON_ITERATIONS
        newtonStats = uint4(0);
        mappingDistance = float2(0.f);
#endif
        uint reservoirIndex = getLinearizedPixel(pixel) * binCount + bin;
        HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
        if (!primaryHit.isValid())
        {
            currReservoirs[reservoirIndex] = Reservoir();
            return float3(0.f);
        }

        Reservoir centralReservoir = prevReservoirs[reservoirIndex];
        // Spatial neighbors first, then adjacent bins; the RNG order of spatial-only reuse is unchanged.
        uint candidateCount = getCandidateCount(binCount, bin);
        if (candidateCount == 0)
        {
            currReservoirs[reservoirIndex] = centralReservoir;
            return float3(centralReservoir.W * centralReservoir.f);
        }

        float3 cameraOrigin = gScene.camera.getPosition();
        ShadingData primary = loadShadingData(primaryHit, cameraOrigin, getPrimaryRayDir(pixel, gFrameDim, gViewW));
        IMaterialInstance primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
        float primaryDepth = length(primary.posW - cameraOrigin);

        SampleGenerator sg = SampleGenerator(pixel, gRandomSeed);
        uint startIndex = sampleNext1D(sg) * kNeighborOffsetCount;
        uint validNeighborCount = 0;
        float canonicalWeight = 1.f;
        Reservoir destination;

        // Split the central mass across the requested candidate pairs. Restore it
        // before the final update; rejected neighbors do not change this split.
        centralReservoir.M /= candidateCount;

        // Prepare the central path's y and suffix once for central -> neighbor weights.
        // A no-RC sample has no valid reconnection payload; its pair weight is one.
        ReconnectionSuffix centralSuffix;
        VertexData centralVertex;
        if (centralReservoir.W > 0 && centralReservoir.rcVertexBounce > 0)
        {
            centralSuffix = loadReconnectionSuffix(centralReservoir, gLaserOrigin, gLaserDirection);
            centralVertex = gScene.getVertexData(centralReservoir.rcVertexHit.getTriangleHit());
        }

        for (uint i = 0; i < candidateCount; ++i)
        {
            int2 neighborPixel;
            uint neighborBin;
            float neighborGateCenter;
            ShadingData neighborPrimary;
            IMaterialInstance neighborMaterial;
            float neighborDepth;
            if (!selectCandidate(pixel, bin, gateCenter, startIndex, i, primary, primaryMaterial, primaryDepth,
                    cameraOrigin, neighborPixel, neighborBin, neighborGateCenter, neighborPrimary, neighborMaterial,
                    neighborDepth))
                continue;

            // Count geometric neighbors even if their reservoir or shift has no support.
            validNeighborCount++;
            Reservoir neighborReservoir = prevReservoirs[getLinearizedPixel(neighborPixel) * binCount + neighborBin];

            // Central -> neighbor: accumulate the central sample's pairwise weight.
            ShiftMappingDebugInfo debugInfo;
            canonicalWeight += evaluateCanonicalShiftWeight(
                centralReservoir, centralSuffix, centralVertex, neighborReservoir.M, getReconnectionCriteria(),
                neighborPrimary, neighborMaterial, neighborDepth,
                neighborGateCenter, gateCenter, sg, debugInfo);

            // Neighbor -> central: shift the neighbor sample and stream it into the reservoir.
            combineReservoirWithShiftMapping(
                destination, neighborReservoir, centralReservoir.M, getReconnectionCriteria(),
                primary, primaryMaterial, primaryDepth,
                gateCenter, neighborGateCenter, 1.f, false,
                gLaserOrigin, gLaserDirection, sg
#if DEBUG_NEWTON_ITERATIONS
                , debugInfo
#endif
            );
#if DEBUG_NEWTON_ITERATIONS
            // Only the neighbor -> central call contributes; canonical evaluation is excluded.
            newtonStats += debugInfo.newtonStats;
            mappingDistance += debugInfo.mappingDistance;
#endif
        }

        return finishReservoir(reservoirIndex, destination, centralReservoir, canonicalWeight, candidateCount,
            validNeighborCount, sg);
    }

#if SPATIAL_REUSE_PAIRS
    uint getPairIndex(uint linearPixel, uint bin, uint i)
    {
        return (i * pairBinCount + (bin - pairFirstBin)) * gFrameDim.x * gFrameDim.y + linearPixel;
    }

    uint getCandidateValidIndex(uint linearPixel, uint i)
    {
        return i * gFrameDim.x * gFrameDim.y + linearPixel;
    }

    // An empty central sample and an empty candidate reservoir (most histogram bins): the canonical coefficient is zero
    // and the candidate contributes only its mass, so the pair needs no shift and no record.
    bool isEmptyPair(uint reservoirIndex, uint neighborReservoirIndex)
    {
        return !(prevReservoirs[reservoirIndex].W > 0) && prevReservoirs[neighborReservoirIndex].W == 0.f;
    }

    // Both shifts of candidate i at one bin, as resampleGate computes them: the central sample's canonical coefficient
    // against the candidate, and the candidate's incoming shift (with the candidate reservoir's M).
    SpatialReusePair evaluateCandidateShifts(uint reservoirIndex, uint neighborReservoirIndex, uint candidateCount,
        ShadingData primary, IMaterialInstance primaryMaterial, float primaryDepth, float gateCenter,
        ShadingData neighborPrimary, IMaterialInstance neighborMaterial, float neighborDepth, float neighborGateCenter,
        inout SampleGenerator sg)
    {
        // Empty reservoirs (most histogram bins) need only W and M: the canonical coefficient of an empty central
        // sample is zero, and an empty candidate contributes only its mass. Load the full reservoirs only otherwise.
        const float centralMass = prevReservoirs[reservoirIndex].M / candidateCount;
        const float neighborM = prevReservoirs[neighborReservoirIndex].M;
        ShiftMappingDebugInfo debugInfo;
        SpatialReusePair pair = {};
        pair.sourceM = neighborM;
        pair.status = kIncomingMassOnly;
        if (prevReservoirs[reservoirIndex].W > 0)
        {
            Reservoir centralReservoir = prevReservoirs[reservoirIndex];
            centralReservoir.M = centralMass;
            // A no-RC sample has no valid reconnection payload; its pair weight is one.
            ReconnectionSuffix centralSuffix;
            VertexData centralVertex;
            if (centralReservoir.rcVertexBounce > 0)
            {
                centralSuffix = loadReconnectionSuffix(centralReservoir, gLaserOrigin, gLaserDirection);
                centralVertex = gScene.getVertexData(centralReservoir.rcVertexHit.getTriangleHit());
            }
            pair.canonical = evaluateCanonicalShiftWeight(
                centralReservoir, centralSuffix, centralVertex, neighborM, getReconnectionCriteria(),
                neighborPrimary, neighborMaterial, neighborDepth, neighborGateCenter, gateCenter, sg, debugInfo);
        }
        if (prevReservoirs[neighborReservoirIndex].W != 0.f)
        {
            IncomingCandidate incoming = evaluateIncomingCandidate(prevReservoirs[neighborReservoirIndex], centralMass,
                getReconnectionCriteria(), primary, primaryMaterial, primaryDepth, gateCenter, neighborGateCenter, 1.f,
                gLaserOrigin, gLaserDirection, sg, debugInfo);
            pair.hit = incoming.hit;
            pair.f = incoming.f;
            pair.weight = incoming.weight;
            pair.prefixEnd = incoming.prefixEnd;
            pair.totalPathLength = incoming.totalPathLength;
            pair.status = incoming.kind;
        }
        return pair;
    }

    // The pair record of pixel's candidate i at `bin` (in the current chunk). Bin centers are binCenter(bin) with
    // useBinCenters (histogram), else gTimeCenter (a time gate). One bin per thread keeps the thread's live state (and
    // registers) small.
    void evaluatePair(uint2 pixel, uint binCount, uint bin, uint i, bool useBinCenters)
    {
        uint candidateCount = getCandidateCount(binCount, bin);
        if (i >= candidateCount) return; // An adjacent bin that does not exist at this bin; never read.
        HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
        if (!primaryHit.isValid()) return;
        uint linearPixel = getLinearizedPixel(pixel);
        uint reservoirIndex = linearPixel * binCount + bin;

        // As resampleGate: the generator picks the neighbors; the shifts draw no random numbers.
        SampleGenerator sg = SampleGenerator(pixel, gRandomSeed);
        uint startIndex = sampleNext1D(sg) * kNeighborOffsetCount;
        int2 neighborPixel;
        uint neighborBin;
        getCandidate(pixel, bin, startIndex, i, neighborPixel, neighborBin);

        // Adjacent bins are always candidates. A spatial neighbor's validity is recorded once per chunk; other threads
        // skip empty pairs before loading anything.
        const bool recordValidity = i < neighborCount && bin == pairFirstBin;
        if (!isValidScreenRegion(neighborPixel))
        {
            if (recordValidity) pairCandidateValid[getCandidateValidIndex(linearPixel, i)] = 0;
            return;
        }
        uint neighborReservoirIndex = getLinearizedPixel(neighborPixel) * binCount + neighborBin;
        const bool empty = isEmptyPair(reservoirIndex, neighborReservoirIndex);
        if (empty && !recordValidity) return;

        float gateCenter = useBinCenters ? binCenter(bin) : gTimeCenter;
        float3 cameraOrigin = gScene.camera.getPosition();
        ShadingData primary = loadShadingData(primaryHit, cameraOrigin, getPrimaryRayDir(pixel, gFrameDim, gViewW));
        IMaterialInstance primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
        float primaryDepth = length(primary.posW - cameraOrigin);
        float neighborGateCenter;
        ShadingData neighborPrimary;
        IMaterialInstance neighborMaterial;
        float neighborDepth;
        bool valid = selectCandidate(pixel, bin, gateCenter, startIndex, i, primary, primaryMaterial, primaryDepth,
            cameraOrigin, neighborPixel, neighborBin, neighborGateCenter, neighborPrimary, neighborMaterial,
            neighborDepth);
        if (recordValidity) pairCandidateValid[getCandidateValidIndex(linearPixel, i)] = uint(valid);
        if (!valid || empty) return;
        pairs[getPairIndex(linearPixel, bin, i)] = evaluateCandidateShifts(reservoirIndex, neighborReservoirIndex,
            candidateCount, primary, primaryMaterial, primaryDepth, gateCenter, neighborPrimary, neighborMaterial,
            neighborDepth, neighborGateCenter, sg);
    }

    // resampleGate from the pair records of evaluatePair (bin in the current chunk): stores the reservoir and returns
    // W * f.
    float3 resampleFromPairs(uint2 pixel, uint binCount, uint bin, float gateCenter)
    {
        uint reservoirIndex = getLinearizedPixel(pixel) * binCount + bin;
        HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
        if (!primaryHit.isValid())
        {
            currReservoirs[reservoirIndex] = Reservoir();
            return float3(0.f);
        }

        Reservoir centralReservoir = prevReservoirs[reservoirIndex];
        uint candidateCount = getCandidateCount(binCount, bin);
        if (candidateCount == 0)
        {
            currReservoirs[reservoirIndex] = centralReservoir;
            return float3(centralReservoir.W * centralReservoir.f);
        }

        SampleGenerator sg = SampleGenerator(pixel, gRandomSeed);
        uint startIndex = sampleNext1D(sg) * kNeighborOffsetCount;
        uint validNeighborCount = 0;
        float canonicalWeight = 1.f;
        Reservoir destination;
        centralReservoir.M /= candidateCount;
        uint linearPixel = getLinearizedPixel(pixel);
        for (uint i = 0; i < candidateCount; ++i)
        {
            if (i < neighborCount && pairCandidateValid[getCandidateValidIndex(linearPixel, i)] == 0) continue;
            validNeighborCount++;
            int2 neighborPixel;
            uint neighborBin;
            getCandidate(pixel, bin, startIndex, i, neighborPixel, neighborBin);
            uint neighborReservoirIndex = getLinearizedPixel(neighborPixel) * binCount + neighborBin;
            // An empty pair has no record: a zero canonical coefficient, and the candidate's mass.
            if (isEmptyPair(reservoirIndex, neighborReservoirIndex))
            {
                destination.M += prevReservoirs[neighborReservoirIndex].M;
                continue;
            }
            SpatialReusePair pair = pairs[getPairIndex(linearPixel, bin, i)];
            canonicalWeight += pair.canonical;
            // As streamIncomingCandidate, reading the candidate's reservoir only for the payload of a selected sample.
            if (pair.status == kIncomingMassOnly)
            {
                destination.M += pair.sourceM;
                continue;
            }
            if (destination.update(pair.f, pair.weight, pair.sourceM, sg))
            {
                copyReconnectionPayload(destination, prevReservoirs[neighborReservoirIndex]);
                destination.rcVertexHit = pair.hit;
                destination.rcPrevVertexPosition = pair.prefixEnd;
                destination.totalPathLength = pair.totalPathLength;
            }
        }
        return finishReservoir(reservoirIndex, destination, centralReservoir, canonicalWeight, candidateCount,
            validNeighborCount, sg);
    }
#endif
}
