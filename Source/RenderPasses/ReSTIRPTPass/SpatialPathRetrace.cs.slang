/***************************************************************************
 # Copyright (c) 2022, Daqi Lin.  All rights reserved.
 **************************************************************************/
import Params;
import Shift;
import Scene.HitInfo;
import PathReservoir;
import PathTracer;
import Scene.Scene;
import Utils.Debug.PixelDebug;
import Rendering.Utils.PixelStats;
import Utils.Sampling.TinyUniformSampleGenerator;
import Utils.Math.Ray;
import Utils.Math.MathHelpers;
import LoadShadingData;
//import Rendering.Materials.MaterialShading;

/** TODO.
*/
struct PathRetracePass
{
    static const uint kNeighborOffsetCount = NEIGHBOR_OFFSET_COUNT;
    static const uint kNeighborOffsetMask = kNeighborOffsetCount - 1;

    // Resources
    RestirPathTracerParams params;                        ///< Runtime parameters.

    Texture2D<PackedHitInfo> vbuffer;                     ///< Fullscreen V-buffer for the primary hits.
    Texture1D<float2> neighborOffsets;

    ByteAddressBuffer nRooksPattern;

    RWTexture2D<float4> outputColor;                      ///< Output resolved color.
    RWStructuredBuffer<PathReservoir> outputReservoirs;                  ///< New per-pixel paths.
    RWStructuredBuffer<PathReservoir> temporalReservoirs;
    RWStructuredBuffer<PixelReconnectionData> reconnectionDataBuffer;

    int gSpatialRoundId;
    int  gNumSpatialRounds;
    uint gSpatialReusePattern;
    // for default pattern
    int gNeighborCount;
    float gGatherRadius;
    // for small window
    int gSmallWindowRadius;

    // for linear growth of M when merging reservoirs

    bool gFeatureBasedRejection;

    bool isValidPackedHitInfo(PackedHitInfo packed)
    {
        return packed.x != 0;
    }

    bool isValidScreenRegion(int2 pixel) { return all(pixel >= 0 && pixel < params.frameDim); }

    bool isValidGeometry(ShadingData centralSd, ShadingData neighborSd)
    {
        return false;
    }

    ShadingData getPixelShadingData(int2 pixel, out PackedHitInfo PrimaryHitPacked)
    {
        ShadingData sd = {};
        return sd;
    }

    int getNeighborCount()
    {
        return gNeighborCount; // does not include self
    }

    int2 getNextNeighborPixel(const uint startIndex, int2 pixel, int i)
    {
        return int2(0, 0);
    }

    /*
    * Build a reservoir of paths whose suffix can be merged to a pixel's prefix.
    * This method is optimized for small windows such that we can run the entire
    * algorithm in one pass.
    */
    void ReSTIR(const uint2 pixel)
    {
        
    }

    /** Entry point for merge pass.
        \param[in] pixel Pixel coordinates.
    */
    void execute(const uint2 _pixel)
    {

    }
};

cbuffer CB
{
    PathRetracePass gPathRetracePass;
}


[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gPathRetracePass.execute(dispatchThreadId.xy);
}
