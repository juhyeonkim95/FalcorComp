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
    Texture2D<float2> gMotionVector; // Optional
    Texture2D<float4> gViewW; // Optional
    
    // Laser V Buffer (1 pixel)
    Texture2D<PackedHitInfo> gLaserVBuffer;
    Texture2D<float4> gLaserViewW;

    // Reservoir Struct
    StructuredBuffer<Reservoir> prevReservoirs;
    RWStructuredBuffer<Reservoir> currReservoirs;
    RWTexture2D<float4> gOutputColor;

    #if USE_SINGLE_CHANNEL
    RWTexture3D<float> gTransientHistogram;
    #else
    RWTexture3D<float4> gTransientHistogram;
    #endif

    
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

            // evaluate
            for(int j=0; j<tbin; j++){
                uint linearizedHistPixel = linearizedPixel * tbin + j;
                currReservoirs[linearizedHistPixel] = prevReservoirs[linearizedHistPixel];
            }

            for(uint i = 0; i<neighborCount; ++i){
                int2 neighborIdx = getNextNeighborPixel(startIndex, pixel, i);

                // check valid pixel
                if(!isValidScreenRegion(neighborIdx)) continue;
                
                const HitInfo hitNeighbor = HitInfo(gVBuffer[neighborIdx]);
                const float3 primaryRayDirNeighbor = -gViewW[neighborIdx].xyz;

                ShadingData sd0prev = loadShadingData(hitNeighbor, primaryRayOrigin, primaryRayDirNeighbor);
                IMaterialInstance mi0prev = gScene.materials.getMaterialInstance(sd0prev, ExplicitLodTextureSampler(0.f));
                float d01prev = length(primaryRayOrigin - sd0prev.posW);
                
                // check valid hit info, similarity
                if(!hitNeighbor.isValid() || !isValidGeometry(sd0, sd0prev, d01, d01prev)) continue;
                uint linearizedPixelPrev = getLinearizedPixel(neighborIdx);

                // iterate over each time bin
                for(int j=0; j<tbin; j++){
                    uint linearizedHistPixelPrev = linearizedPixelPrev * tbin + j;
                    Reservoir prevReservoir = prevReservoirs[linearizedHistPixelPrev];
                    VertexData prev_x2 = gScene.getVertexData(prevReservoir.rcVertexHit.getTriangleHit());
                    float newPathLength = d01 + length(sd0.posW - prev_x2.posW) + prevReservoir.rcVertexPostPathLength;
                        
                    uint pathLengthIdx;
                    float pathLengthIdxResidual;
                    if(getPathLengthIndex(newPathLength, pathLengthIdx, pathLengthIdxResidual))
                    {
                        float M_temp = prevReservoir.M;
                        {
                            uint linearizedHistPixelCurr = linearizedPixel * tbin + pathLengthIdx;
                        
                            Reservoir currReservoir = currReservoirs[linearizedHistPixelCurr];

                            Reservoir dstReservoir;

                            prevReservoir.M = M_temp;

                            combine_reservoir_with_shiftmapping(
                                dstReservoir,
                                prevReservoir,
                                currReservoir.M,
                                sd0, mi0, d01,
                                false, pathLengthIdx,
                                false,
                                sg
                            );

                            // combine_reservoir_with_shiftmapping(
                            //     dstReservoir,
                            //     currReservoir,
                            //     prevReservoir.M,
                            //     sd0prev, mi0prev, d01prev,
                            //     false, j,
                            //     true,
                            //     sg
                            // );

                            float pHat = getReservoirWeight(dstReservoir.f);
                            dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
                            currReservoirs[linearizedHistPixelCurr] = dstReservoir;
                        }
                    }
                }
            }

            // evaluate
            for(int j=0; j<tbin; j++){
                uint linearizedHistPixel = linearizedPixel * tbin + j;
                float3 L = currReservoirs[linearizedHistPixel].W * currReservoirs[linearizedHistPixel].f;
                L /= tunit;
                #if USE_SINGLE_CHANNEL
                gTransientHistogram[uint3(pixel.x, pixel.y, j)] += getReservoirWeight(L);
                #else
                gTransientHistogram[uint3(pixel.x, pixel.y, j)] += float4(L, 1.0);
                #endif
            }
        }

        return float3(1.0);
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
}
