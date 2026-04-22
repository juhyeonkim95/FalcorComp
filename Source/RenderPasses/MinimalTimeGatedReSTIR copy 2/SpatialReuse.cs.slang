import Utils.Math.MathHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Reservoirs;
import LoadShadingData;
import TransientShiftmapping;
import Utils.Transient.Ellipsoid;
import Utils.Transient.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Utils.Color.ColorHelpers;

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
}

struct SpatialReuse
{
    // Static configuration.
    static const uint kNeighborOffsetCount = NEIGHBOR_OFFSET_COUNT;
    static const uint kNeighborOffsetMask = kNeighborOffsetCount - 1;

    // NeighborSampling
    Texture1D<float2> neighborOffsets;
    
    static const float normalThreshold = 0.7f;
    static const float depthThreshold = 0.1f;

    uint neighborCount;     ///< Number of neighbor reservoirs to resample.
    float gatherRadius;     ///< Maximum radius to gather neighbors from.

    uint gFrameCount;
    uint gRandomSeed;
    uint2 gFrameDim;

    // Inputs
    Texture2D<PackedHitInfo> gVBuffer;
    Texture2D<float4> gViewW; // Optional
    
    // Laser V Buffer (1 pixel)
    Texture2D<PackedHitInfo> gLaserVBuffer;
    Texture2D<float4> gLaserViewW;

    // Reservoir Struct
    StructuredBuffer<Reservoir> prevReservoirs;
    RWStructuredBuffer<Reservoir> currReservoirs;
    RWTexture2D<float4> gOutputColor;

    uint getLinearizedPixel(uint2 pixel){
        return pixel.y * gFrameDim.x + pixel.x;
    }

    int2 getNextNeighborPixel(const uint startIndex, int2 pixel, int i)
    {
        uint neighborIndex = (startIndex + i) & kNeighborOffsetMask;
        int2 neighborPixel = pixel + int2(neighborOffsets[neighborIndex] * gatherRadius);

        return neighborPixel;
    }

    bool isValidGeometry(const ShadingData sd1, const ShadingData sd2, float d1, float d2){
        return  dot(sd1.getOrientedFaceNormal(), sd2.getOrientedFaceNormal()) > normalThreshold 
                    && abs(d1 - d2) < depthThreshold * d1 && 
                    (sd1.materialID == sd2.materialID);
    }
    
    bool isValidScreenRegion(int2 pixel) { return all(pixel >= 0 && pixel < gFrameDim); }

    float3 process(uint2 pixel){
        float3 outColor;
        const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

        if (hit0.isValid()){
            
            const uint linearizedPixel = getLinearizedPixel(pixel);
            Reservoir centralReservoir = prevReservoirs[linearizedPixel];
            // outColor = centralReservoir.W * centralReservoir.f;
            // currReservoirs[linearizedPixel] = centralReservoir;
            // return outColor;

            const float3 primaryRayOrigin = gScene.camera.getPosition();
            const float3 primaryRayDir = -gViewW[pixel].xyz;
            
            ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
            IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
            float d01 = length(sd0.posW - primaryRayOrigin);
            BSDFProperties bsdfProperties0 = mi0.getProperties(sd0);

            SampleGenerator sg = SampleGenerator(pixel, gRandomSeed);
            const uint startIndex = sampleNext1D(sg) * kNeighborOffsetCount;

            int validNeighborCount = 0;
            float canonicalWeight = 1;

            // temporaraliy reduce M
            centralReservoir.M /= neighborCount;

            Reservoir dstReservoir;
            ShadingData curr_x3;
            IMaterialInstance curr_x3_mi;
            VertexData v_curr;
            if(centralReservoir.W > 0){
                curr_x3 = loadShadingData(centralReservoir.rcNextVertexHit, 
                    float3(0.0), centralReservoir.rcNextVertexWi);
                curr_x3_mi = gScene.materials.getMaterialInstance(curr_x3, 
                    ExplicitLodTextureSampler(0.f));
                v_curr = gScene.getVertexData(centralReservoir.rcVertexHit.getTriangleHit());
            }
            
            float moved_distance_total = 0.0;
            float moved_distance_total_count = 0;

            for(uint i = 0; i<neighborCount; ++i){
                int2 neighborIdx = getNextNeighborPixel(startIndex, pixel, i);

                // check valid pixel
                if(!isValidScreenRegion(neighborIdx)) continue;

                const HitInfo hitNeighbor = HitInfo(gVBuffer[neighborIdx]);
                const float3 primaryRayDirNeighbor = -gViewW[neighborIdx].xyz;
                ShadingData sdNeighbor = loadShadingData(hitNeighbor, primaryRayOrigin, primaryRayDirNeighbor);
                float d01Neighbor = length(sdNeighbor.posW - primaryRayOrigin);
                
                // check valid hit info, similarity
                if(!hitNeighbor.isValid() || !isValidGeometry(sd0, sdNeighbor, d01, d01Neighbor)) continue;
                
                validNeighborCount++;

                uint neighborIdxLinearized = getLinearizedPixel(neighborIdx);
                Reservoir neighborReservoir = prevReservoirs[neighborIdxLinearized];
                
                IMaterialInstance miNeighbor = gScene.materials.getMaterialInstance(sdNeighbor, 
                    ExplicitLodTextureSampler(0.f));
                
                // we don't update reservoir here --> update will be performed at last
                canonicalWeight += evaluate_canonical_shiftmap_weight(
                    centralReservoir,
                    curr_x3, v_curr, curr_x3_mi,
                    neighborReservoir.M, 
                    sdNeighbor, miNeighbor, d01Neighbor,
                    tcurr, tcurr,
                    sg
                );
                
                float moved_distance = 0.0;
                // for neighbor reservoir, we update dstReservoir
                combine_reservoir_with_shiftmapping(
                    dstReservoir,
                    neighborReservoir,
                    centralReservoir.M,
                    sd0, mi0, d01,
                    tcurr, tcurr,
                    1.0,
                    false, // this is not canonical
                    // moved_distance,
                    sg
                );

                // eval how much moved (add only valid)
                // if(neighborReservoir.W > 0 && moved_distance > 0){
                //     moved_distance_total += moved_distance;
                //     moved_distance_total_count += 1;
                // }
            }


            float pHat_proxy_curr_as_curr = luminance(centralReservoir.f);
            float weight_curr = canonicalWeight * pHat_proxy_curr_as_curr * centralReservoir.W;
            
            // revert M
            centralReservoir.M *= neighborCount;

            if(dstReservoir.update(centralReservoir.f, weight_curr, centralReservoir.M, sg)){
                dstReservoir.rcVertexHit = centralReservoir.rcVertexHit;
                dstReservoir.rcNextVertexHit = centralReservoir.rcNextVertexHit;
                dstReservoir.rcNextVertexWi = centralReservoir.rcNextVertexWi;
                dstReservoir.rcNextVertexIrradiance = centralReservoir.rcNextVertexIrradiance;
                dstReservoir.rcNextVertexPathLength = centralReservoir.rcNextVertexPathLength;
                dstReservoir.rcVertexPathLength = centralReservoir.rcVertexPathLength;
                dstReservoir.rcVertexBounce = centralReservoir.rcVertexBounce;
                dstReservoir.initRandomSeed = centralReservoir.initRandomSeed;
            }
            
            float pHat_new = luminance(dstReservoir.f);
            dstReservoir.W = (pHat_new == 0.0) ? 0 : (1.0f / pHat_new) * dstReservoir.wSum;
            dstReservoir.W /= (validNeighborCount + 1);

            outColor = dstReservoir.W * dstReservoir.f;
            currReservoirs[linearizedPixel] = dstReservoir;
            if (any(isinf(outColor) || isnan(outColor))) outColor = 0.f;
            //if(any(outColor) > 0.5) outColor = 0.f;
            // float avg_moved_distance = moved_distance_total_count == 0.0 ? 0.0 : moved_distance_total / moved_distance_total_count;
            // return float3(moved_distance_total, moved_distance_total_count, 0);

            return outColor;
        }
        return float3(0.0);
    }
}

cbuffer CB
{
    SpatialReuse gSpatialReuse;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    float3 color = gSpatialReuse.process(pixel);
    gSpatialReuse.gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
    // gSpatialReuse.gOutputColor[pixel] = float4(color, 1.f);
}
