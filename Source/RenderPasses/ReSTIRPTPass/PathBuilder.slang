/***************************************************************************
 # Copyright (c) 2022, Daqi Lin.  All rights reserved.
 **************************************************************************/
// #include "Scene/Material/MaterialDefines.slangh"

//import Rendering.Materials.MaterialShading;
import LoadShadingData;
import Utils.Debug.PixelDebug;
import Utils.Math.HashUtils;
import Params;
import PathReservoir;
import Rendering.Utils.PixelStats;
import Scene.RaytracingInline;
import Utils.Sampling.TinyUniformSampleGenerator;

#if BPR
static const int kRcWiCount = 2;
#else
static const int kRcWiCount = 1;
#endif

/// Builds a Path and a PathPrefix.
struct PathBuilder
{
    TriMeshHitInfo rcVertexHit;
    float3 rcVertexWi[kRcWiCount];
    uint cachedRandomSeed;
    TinyUniformSampleGenerator sg;
    int rcVertexLength = kMaximumPathLength;
    ReSTIRPathFlags pathFlags;
    float3 cachedJacobian = 1.f;

    [mutating]
    void init<S : ISampleGenerator>(inout S sg)
    {
        this.sg = TinyUniformSampleGenerator(jenkinsHash(sg.next()));
        rcVertexWi[0] = float3(0.f);
        rcVertexHit.instanceID = 0xffffffff;
#if BPR
        rcVertexWi[1] = float3(0.f);
#endif
    }

    void finalize(inout PathReservoir pathReservoir)
    {

    }

    [mutating]
    bool addEscapeVertex(RestirPathTracerParams params, uint pathLength, float3 wi, float3 pathWeight, float3 postfixWeight, bool useHybridShift,
        float russianroulettePDF, float misWeight, float lightPdf, int lightType, inout PathReservoir pathReservoir, bool forceAdd = false)
    {
        return false;
    }

    [mutating]
    bool addNeeVertex(RestirPathTracerParams params, uint pathLength, float3 wi, float3 pathWeight, float3 postfixWeight, bool useHybridShift,
        float russianroulettePDF, float misWeight, float lightPdf, int lightType, inout PathReservoir pathReservoir, bool forceAdd = false)
    {
        return false;
    }

    [mutating] void markEscapeVertexAsRcVertex(RestirPathTracerParams params, uint pathLength, inout PathReservoir pathReservoir, HitInfo hit, bool isDelta,
        bool isTransmission, bool isSpecularBounce, float lightPdf, uint lightType, float3 rcVertexIrradiance, float3 rcVertexWi, float prevScatterPdf, float geometryFactor)
    {
    }
};

