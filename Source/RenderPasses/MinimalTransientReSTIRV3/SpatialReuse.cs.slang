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
    Texture2D<float2> gMotionVector; // Optional
    
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
