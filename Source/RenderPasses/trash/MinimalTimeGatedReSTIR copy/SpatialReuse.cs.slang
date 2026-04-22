import Utils.Math.MathHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Reservoirs;
import LoadShadingData;
import TransientShiftmapping;


struct SpatialReuse
{
    // Static configuration.
    static const uint kNeighborOffsetCount = NEIGHBOR_OFFSET_COUNT;
    static const uint kNeighborOffsetMask = kNeighborOffsetCount - 1;

    // NeighborSampling
    Texture1D<float2> neighborOffsets;
    
    static const float normalThreshold = 0.8f;
    static const float depthThreshold = 0.1f;

    static const uint neighborCount = 5;     ///< Number of neighbor reservoirs to resample.
    static const float gatherRadius = 10;     ///< Maximum radius to gather neighbors from.

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


    float3 process(uint2 pixel){
        float3 outColor;
        const uint linearizedPixel = getLinearizedPixel(pixel);
        Reservoir curr_reservoir = prevReservoirs[linearizedPixel];
        //outColor = curr_reservoir.W * curr_reservoir.f;
        //return outColor;

        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = -gViewW[pixel].xyz;
        const HitInfo hit0 = HitInfo(gVBuffer[pixel]);
        
        if (hit0.isValid()){
            ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
            IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
            float d01 = length(sd0.posW - primaryRayOrigin);

            //
            // Laser Hit Material
            //
            const HitInfo laserhit = HitInfo(gLaserVBuffer[uint2(0,0)]);
            const float4 laserViewW = gLaserViewW[uint2(0,0)];
            const float laserT = laserViewW.w;
            ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laserDirection);
            let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
            
            SampleGenerator sg = SampleGenerator(pixel, gRandomSeed);
            const uint startIndex = sampleNext1D(sg) * kNeighborOffsetCount;

            for(uint i = 0; i<neighborCount; ++i){
                int2 neightIdx = getNextNeighborPixel(startIndex, pixel, i);
                // int2 d = int2(gatherRadius * sample_disk(sampleNext2D(sg)));
                // uint2 neightIdx = pixel + d;
                neightIdx = clamp(neightIdx, uint2(0, 0), gFrameDim - 1);
                uint neightIdxLinearized = getLinearizedPixel(neightIdx);
                Reservoir prev_reservoir = prevReservoirs[neightIdxLinearized];
                
                const HitInfo hitNeighbor = HitInfo(gVBuffer[neightIdx]);
                const float3 primaryRayDirNeighbor = -gViewW[neightIdx].xyz;
                ShadingData sdNeighbor = loadShadingData(hitNeighbor, primaryRayOrigin, primaryRayDirNeighbor);
    
                if(dot(sd0.getOrientedFaceNormal(), sdNeighbor.getOrientedFaceNormal()) > 0.9 
                    && length(sd0.posW - sdNeighbor.posW) < 0.1
                ){
                    IMaterialInstance miNeighbor = gScene.materials.getMaterialInstance(sdNeighbor, 
                        ExplicitLodTextureSampler(0.f));
                    float d01Neighbor = length(sdNeighbor.posW - primaryRayOrigin);
                    
                    curr_reservoir = combine_reservoirs_with_shiftmapping(
                        prev_reservoir, curr_reservoir,
                        sdNeighbor, sd0,
                        d01Neighbor, d01,
                        0.0,
                        sg
                    );
                }
            }
            outColor = curr_reservoir.W * curr_reservoir.f;
            // outColor = laserOrigin;
            currReservoirs[linearizedPixel] = curr_reservoir;
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
    gSpatialReuse.gOutputColor[pixel] = float4(color / min(1.0, time_gate_window), 1.f);
    // gSpatialReuse.gOutputColor[pixel] = float4(color, 1.f);
}
