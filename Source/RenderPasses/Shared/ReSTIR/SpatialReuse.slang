// Spatial reuse shared by the time-gated and histogram ReSTIR passes.
// Reservoirs are stored as [pixel * binCount + bin]; a time-gated pass is the
// single-bin case (binCount = 1, bin = 0, gateCenter = tcurr).
import Utils.Sampling.SampleGenerator;
import Utils.Transient.TransientUtils;
import RenderPasses.Shared.ReSTIR.Reservoirs;
import RenderPasses.Shared.ReSTIR.PathReconstruction;
import RenderPasses.Shared.ReSTIR.ReservoirReuse;
import RenderPasses.Shared.Utils.LoadShadingData;
import RenderPasses.Shared.ReSTIR.PathLengthAwareShiftmapping;

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
}

struct SpatialReuse
{
    static const uint kNeighborOffsetCount = NEIGHBOR_OFFSET_COUNT;
    static const uint kNeighborOffsetMask = kNeighborOffsetCount - 1;
    static const float kNormalThreshold = 0.7f;
    static const float kDepthThreshold = 0.1f;

    Texture1D<float2> neighborOffsets;
    uint neighborCount;
    float specularRoughnessThreshold;
    float gatherRadius;

    uint gFrameCount;
    uint gRandomSeed;
    uint2 gFrameDim;

    // Keep shader interface fields in sync with the C++ resource bindings.
    Texture2D<PackedHitInfo> gVBuffer;
    Texture2D<float4> gViewW;
    Texture2D<float2> gMotionVector; // Optional
    Texture2D<PackedHitInfo> gLaserVBuffer;
    Texture2D<float4> gLaserViewW;

    StructuredBuffer<Reservoir> prevReservoirs;
    RWStructuredBuffer<Reservoir> currReservoirs;
    RWTexture2D<float4> gOutputColor;
#if DEBUG_NEWTON_ITERATIONS
    RWTexture2D<uint4> gNewtonStatistics;
    RWTexture2D<float2> gMappingDistance;
#endif

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
        if (neighborCount == 0)
        {
            currReservoirs[reservoirIndex] = centralReservoir;
            return centralReservoir.W * centralReservoir.f;
        }

        float3 cameraOrigin = gScene.camera.getPosition();
        ShadingData primary = loadShadingData(primaryHit, cameraOrigin, -gViewW[pixel].xyz);
        IMaterialInstance primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
        float primaryDepth = length(primary.posW - cameraOrigin);

        SampleGenerator sg = SampleGenerator(pixel, gRandomSeed);
        uint startIndex = sampleNext1D(sg) * kNeighborOffsetCount;
        uint validNeighborCount = 0;
        float canonicalWeight = 1.f;
        Reservoir destination;

        // Split the central mass across the requested neighbor pairs. Restore it
        // before the final update; rejected neighbors do not change this split.
        centralReservoir.M /= neighborCount;

        // Prepare the central path's x and y once for central -> neighbor weights.
        // A no-RC sample has no valid reconnection payload; its pair weight is one.
        ShadingData centralNextVertex;
        IMaterialInstance centralNextMaterial;
        VertexData centralVertex;
        if (centralReservoir.W > 0 && centralReservoir.rcVertexBounce > 0)
        {
            if (centralReservoir.rcNextVertexHit.isValid())
            {
                centralNextVertex = loadShadingData(centralReservoir.rcNextVertexHit,
                    float3(0.f), centralReservoir.rcNextVertexWi);
                centralNextMaterial = gScene.materials.getMaterialInstance(centralNextVertex, ExplicitLodTextureSampler(0.f));
            }
            else
            {
                centralNextVertex.posW = laserOrigin;
                centralNextVertex.frontFacing = true;
                centralNextVertex.faceN = laserDirection;
            }
            centralVertex = gScene.getVertexData(centralReservoir.rcVertexHit.getTriangleHit());
        }

        for (uint i = 0; i < neighborCount; ++i)
        {
            int2 neighborPixel = getNextNeighborPixel(startIndex, pixel, i);
            if (!isValidScreenRegion(neighborPixel)) continue;
            // Integer offsets may select this pixel, particularly at radius zero.
            if (all(neighborPixel == int2(pixel))) continue;

            HitInfo neighborHit = HitInfo(gVBuffer[neighborPixel]);
            if (!neighborHit.isValid()) continue;
            ShadingData neighborPrimary = loadShadingData(neighborHit, cameraOrigin, -gViewW[neighborPixel].xyz);
            float neighborDepth = length(neighborPrimary.posW - cameraOrigin);
            if (!isValidGeometry(primary, neighborPrimary, primaryDepth, neighborDepth)) continue;

            // Count geometric neighbors even if their reservoir or shift has no support.
            validNeighborCount++;
            Reservoir neighborReservoir = prevReservoirs[getLinearizedPixel(neighborPixel) * binCount + bin];
            IMaterialInstance neighborMaterial = gScene.materials.getMaterialInstance(neighborPrimary, ExplicitLodTextureSampler(0.f));

            // Central -> neighbor: accumulate the central sample's pairwise weight.
            ShiftMapDebugInfo debugInfo;
            canonicalWeight += evaluate_canonical_shiftmap_weight(
                centralReservoir,
                centralNextVertex, centralVertex, centralNextMaterial,
                neighborReservoir.M,
                primary, primaryMaterial, primaryDepth, specularRoughnessThreshold,
                neighborPrimary, neighborMaterial, neighborDepth,
                gateCenter, gateCenter, sg, debugInfo);

            // Neighbor -> central: shift the neighbor sample and stream it into the reservoir.
            combine_reservoir_with_shiftmapping(
                destination, neighborReservoir, centralReservoir.M,
                neighborPrimary, neighborMaterial, neighborDepth, specularRoughnessThreshold,
                primary, primaryMaterial, primaryDepth,
                gateCenter, gateCenter, 1.f, false,
                laserOrigin, laserDirection, sg
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
        centralReservoir.M *= neighborCount;
        if (destination.update(centralReservoir.f, centralWeight, centralReservoir.M, sg))
            copySelectedPath(destination, centralReservoir);

        float selectedTarget = getReservoirWeight(destination.f);
        destination.W = (selectedTarget == 0.f) ? 0.f : destination.wSum / selectedTarget;
        destination.W /= validNeighborCount + 1;
        currReservoirs[reservoirIndex] = destination;

        float3 color = destination.W * destination.f;
        if (any(isinf(color) || isnan(color))) color = 0.f;
        return color;
    }
}
