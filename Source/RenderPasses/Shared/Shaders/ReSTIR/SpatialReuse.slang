// Spatial reuse shared by the time-gated and histogram ReSTIR passes.
// Reservoirs are stored as [pixel * binCount + bin]; a time-gated pass is the
// single-bin case (binCount = 1, bin = 0, gateCenter = gTimeCenter).
// With useBinReuse, the adjacent bins (bin - 1, bin + 1) of the same pixel are
// additional candidates in the same pairwise MIS as the spatial neighbors. Their
// paths are shifted by one bin width with the path-length-aware shift mapping.
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
        uint candidateCount = neighborCount + getAdjacentBinCount(binCount, bin);
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
            // A candidate is a spatial neighbor at the same bin, or this pixel at an adjacent bin.
            int2 neighborPixel = int2(pixel);
            uint neighborBin = bin;
            float neighborGateCenter = gateCenter;
            ShadingData neighborPrimary = primary;
            IMaterialInstance neighborMaterial = primaryMaterial;
            float neighborDepth = primaryDepth;
            if (i < neighborCount)
            {
                neighborPixel = getNextNeighborPixel(startIndex, pixel, i);
                if (!isValidScreenRegion(neighborPixel)) continue;
                // Integer offsets may select this pixel, particularly at radius zero.
                if (all(neighborPixel == int2(pixel))) continue;

                HitInfo neighborHit = HitInfo(gVBuffer[neighborPixel]);
                if (!neighborHit.isValid()) continue;
                neighborPrimary = loadShadingData(neighborHit, cameraOrigin, getPrimaryRayDir(uint2(neighborPixel), gFrameDim, gViewW));
                neighborDepth = length(neighborPrimary.posW - cameraOrigin);
                if (!isValidGeometry(primary, neighborPrimary, primaryDepth, neighborDepth)) continue;
                neighborMaterial = gScene.materials.getMaterialInstance(neighborPrimary, ExplicitLodTextureSampler(0.f));
            }
            else
            {
                neighborBin = getAdjacentBin(bin, i - neighborCount);
                neighborGateCenter = binCenter(neighborBin);
            }

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

        // Add the unshifted central sample after all neighbor updates, preserving RNG order.
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
}
