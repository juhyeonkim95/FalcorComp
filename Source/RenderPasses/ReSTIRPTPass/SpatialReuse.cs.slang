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
import RenderPasses.Shared.Denoising.NRDData;
import RenderPasses.Shared.Denoising.NRDBuffers;
import RenderPasses.Shared.Denoising.NRDConstants;
// import NRDHelpers;

struct PathReusePass
{
    static const uint kNeighborOffsetCount = NEIGHBOR_OFFSET_COUNT;
    static const uint kNeighborOffsetMask = kNeighborOffsetCount - 1;

    // Resources
    RestirPathTracerParams params;                        ///< Runtime parameters.

    Texture2D<PackedHitInfo> vbuffer;                     ///< Fullscreen V-buffer for the primary hits.
    Texture1D<float2> neighborOffsets;

    ByteAddressBuffer nRooksPattern;

    RWTexture2D<float4> outputColor;                      ///< Output resolved color.
    StructuredBuffer<PathReservoir> outputReservoirs;     // reservoir from previous pass
    RWStructuredBuffer<PathReservoir> temporalReservoirs; // resulting reservoir for next frame
    StructuredBuffer<PixelReconnectionData> reconnectionDataBuffer;
    StructuredBuffer<PathReuseMISWeight> misWeightBuffer;

    RWTexture2D<float4> outputNRDDiffuseRadianceHitDist;    ///< Output resolved diffuse color in .rgb and hit distance in .a for NRD. Only valid if kOutputNRDData == true.
    RWTexture2D<float4> outputNRDSpecularRadianceHitDist;   ///< Output resolved specular color in .rgb and hit distance in .a for NRD. Only valid if kOutputNRDData == true.
    RWTexture2D<float4> outputNRDResidualRadianceHitDist;   ///< Output resolved residual color in .rgb and hit distance in .a for NRD. Only valid if kOutputNRDData == true.
    Texture2D<float4> primaryHitEmission;                     ///< Output per-pixel primary hit emission. Only valid if kOutputNRDData == true.

    int gSpatialRoundId;
    int  gNumSpatialRounds;
    uint gSpatialReusePattern;
    // for default pattern
    int gNeighborCount;
    float gGatherRadius;
    // for small window
    int gSmallWindowRadius;

    bool gIsLastRound;

    bool gFeatureBasedRejection;

    uint gSppId;

    Texture2D<float4> directLighting;  
    bool useDirectLighting;

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
        return 1;
    }

    int2 getPathReuseNextNeighborPixel(int4 NRookQuery, int2 pixel, int i)
    {
        return int2(0, 0);
    }

    int2 getNextNeighborPixel(const uint startIndex, int2 pixel, int i)
    {
        return int2(0, 0);
    }

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
    PathReusePass gPathReusePass;
}


[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gPathReusePass.execute(dispatchThreadId.xy);
}
