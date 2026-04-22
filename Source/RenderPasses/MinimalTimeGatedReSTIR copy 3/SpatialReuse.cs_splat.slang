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
    EmissiveLightSampler emissiveSampler;           ///< Emissive light sampler. Only valid when kUseEmissiveLights == true.


    // Inputs
    Texture2D<PackedHitInfo> gVBuffer;
    Texture2D<float4> gViewW; // Optional


    // Laser V Buffer (1 pixel)
    Texture2D<PackedHitInfo> gLaserVBuffer;
    Texture2D<float4> gLaserViewW;

    // Reservoir Struct
    StructuredBuffer<Reservoir> reservoirs;
    RWStructuredBuffer<Reservoir> splatReservoirs;
    RWBuffer<uint>      gLocks;       // same size, 0 = unlocked, 1 = locked

    void acquireLock(uint idx)
    {
        uint old;
        [loop]
        while (true)
        {
            // Try to change 0 -> 1 atomically.
            // dest, compare, value, original
            InterlockedCompareExchange(gLocks[idx], 0, 1, old);
            if (old == 0) break; // success
            // else: someone else holds the lock, spin
        }
    }

    void releaseLock(uint idx)
    {
        // No atomic needed; only the owner writes 0.
        gLocks[idx] = 0;
    }

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

    float2 getPixelfromPosW(float3 posW){
        float4 posH = mul(gScene.camera.getViewProj(), float4(posW, 1.f));
        float3 ndc = posH.xyz / posH.w;

        float2 pixel;
        pixel.x = (ndc.x * 0.5 + 0.5) * gFrameDim.x;
        pixel.y = (1.0 - (ndc.y * 0.5 + 0.5)) * gFrameDim.y;

        return pixel;
    }

    void process(uint2 pixel){
        float3 outColor;
        const uint linearizedPixel = getLinearizedPixel(pixel);
        Reservoir reservoir = reservoirs[linearizedPixel];
        // outColor = curr_reservoir.W * curr_reservoir.f;
        // return outColor;

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
            
            float tSampled = d01 + length(sd0.posW - reservoir.lightSample.p);

            Ellipsoid E;
            if(!buildEllipsoidFromFoci(
                sd0.posW, primaryRayOrigin, tSampled,
                sd0.getOrientedFaceNormal(), primaryRayDir, E)){  
                return;
            }
            
            for(uint i = 0; i<neighborCount; ++i){
                uint triangleIndex;
                float trianglePdf;
                if(!emissiveSampler.sampleTriangleEllipsoid(
                    E, sg, triangleIndex, trianglePdf)){
                        continue;
                    }
                    
                const EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);
                SampleResultArea result = sampleOnTriangleEllipsoid(
                    E,
                    tri.posW[0], tri.posW[1], tri.posW[2],
                    sampleNext1D(sg), sampleNext1D(sg));
                    
                int2 neighborIdx = getPixelfromPosW(result.p);

                if(result.ok && (neighborIdx.x >= 0 && neighborIdx.x < gFrameDim.x && neighborIdx.y >=0 && neighborIdx.y < gFrameDim.y))
                {
                    uint neighborIdxLinearized = getLinearizedPixel(neighborIdx);
                    acquireLock(neighborIdxLinearized);
                    Reservoir splatReservoir = splatReservoirs[neighborIdxLinearized];

                    const HitInfo hitNeighbor = HitInfo(gVBuffer[neighborIdx]);
                    const float3 primaryRayDirNeighbor = -gViewW[neighborIdx].xyz;
                    ShadingData sdNeighbor = loadShadingData(hitNeighbor, primaryRayOrigin, primaryRayDirNeighbor);

                    // if(dot(sd0.getOrientedFaceNormal(), sdNeighbor.getOrientedFaceNormal()) > 0.9 
                    //     && length(sd0.posW - sdNeighbor.posW) < 0.1
                    // )
                    {
                        IMaterialInstance miNeighbor = gScene.materials.getMaterialInstance(sdNeighbor, 
                            ExplicitLodTextureSampler(0.f));
                        float d01Neighbor = length(sdNeighbor.posW - primaryRayOrigin);
                        
                        // Acquire per-pixel lock
                        splatReservoirs[neighborIdxLinearized] =  combine_reservoirs_with_shiftmapping(
                            reservoir, splatReservoir,
                            sd0, sdNeighbor,
                            laser_sd, 
                            d01, d01Neighbor,
                            laserT,
                            0.0,
                            sg
                        );
                        // Release lock
                    }
                    releaseLock(neighborIdxLinearized);
                }
                // getNextNeighborPixel(startIndex, pixel, i);
                // int2 d = int2(gatherRadius * sample_disk(sampleNext2D(sg)));
                // uint2 neighborIdx = pixel + d;
                // neighborIdx = clamp(neighborIdx, uint2(0, 0), gFrameDim - 1);
                // uint neighborIdxLinearized = getLinearizedPixel(neighborIdx);
                // Reservoir prev_reservoir = prevReservoirs[neighborIdxLinearized];
                
                // const HitInfo hitNeighbor = HitInfo(gVBuffer[neighborIdx]);
                // const float3 primaryRayDirNeighbor = -gViewW[neighborIdx].xyz;
                // ShadingData sdNeighbor = loadShadingData(hitNeighbor, primaryRayOrigin, primaryRayDirNeighbor);
    
                // if(dot(sd0.getOrientedFaceNormal(), sdNeighbor.getOrientedFaceNormal()) > 0.9 
                //     && length(sd0.posW - sdNeighbor.posW) < 0.1
                // ){
                //     IMaterialInstance miNeighbor = gScene.materials.getMaterialInstance(sdNeighbor, 
                //         ExplicitLodTextureSampler(0.f));
                //     float d01Neighbor = length(sdNeighbor.posW - primaryRayOrigin);
                    
                //     curr_reservoir = combine_reservoirs_with_shiftmapping(
                //         prev_reservoir, curr_reservoir,
                //         sdNeighbor, sd0,
                //         laser_sd, 
                //         d01Neighbor, d01,
                //         laserT,
                //         0.0,
                //         sg
                //     );
                // }
            }
            return;
        }
        return;
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
    gSpatialReuse.process(pixel);
    //float3 color =
    //  gSpatialReuse.gOutputColor[pixel] = float4(color / min(1.0, time_gate_window), 1.f);
    //gSpatialReuse.gOutputColor[pixel] = float4(color, 1.f);
}
