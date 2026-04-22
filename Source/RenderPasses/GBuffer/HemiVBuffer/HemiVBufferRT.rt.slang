/***************************************************************************
 # Copyright (c) 2015-24, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.Raytracing;
import Scene.Intersection;
import Scene.SDFs.SDFGridHitData;
import HemiVBufferRT;
import Utils.Math.MathHelpers;


ConstantBuffer<HemiParams> gHemi;
ConstantBuffer<HemiVBufferRT> gHemiVBufferRT;

struct RayData
{
    // TODO: Passing in an empty payload struct doesn't work. Declare a dummy variable so that the compiler doesn't remove the declaration.
    float t;
};


//
// Shader entry point for miss shader.
//

[shader("miss")]
void miss(inout RayData rayData)
{
    // Write invalid hit to output buffer.
    uint2 launchIndex = DispatchRaysIndex().xy;
    gHemiVBufferRT.writeMiss(launchIndex, WorldRayOrigin(), WorldRayDirection());
    rayData.t = 0.0;
}


//
// Shader entry points for TriangleMesh hit groups.
//

[shader("anyhit")]
void anyHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    if (HemiVBufferRT::kUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Store hit information. Note we don't access the materials here.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    // Write hit info to output buffer.
    uint2 launchIndex = DispatchRaysIndex().xy;
    gHemiVBufferRT.writeHit(launchIndex, WorldRayOrigin(), WorldRayDirection(), HitInfo(triangleHit));
    rayData.t = RayTCurrent();
}

//
// Shader entry points for DisplacedTriangleMesh hit groups.
//

[shader("intersection")]
void displacedTriangleMeshIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    DisplacedTriangleMeshIntersector::Attribs attribs;
    float t;
    if (DisplacedTriangleMeshIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), attribs, t))
    {
        ReportHit(t, 0, attribs);
    }
}

[shader("closesthit")]
void displacedTriangleMeshClosestHit(inout RayData rayData, DisplacedTriangleMeshIntersector::Attribs attribs)
{
    // Store hit information. Note we don't access the materials here.
    DisplacedTriangleHit displacedTriangleHit;
    displacedTriangleHit.instanceID = getGeometryInstanceID();
    displacedTriangleHit.primitiveIndex = PrimitiveIndex();
    displacedTriangleHit.barycentrics = attribs.barycentrics;
    displacedTriangleHit.displacement = attribs.displacement;

    // Write hit info to output buffer.
    uint2 launchIndex = DispatchRaysIndex().xy;
    gHemiVBufferRT.writeHit(launchIndex, WorldRayOrigin(), WorldRayDirection(), HitInfo(displacedTriangleHit));
    rayData.t = RayTCurrent();
}

//
// Shader entry points for Curve hit groups.
//

[shader("intersection")]
void curveIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    CurveIntersector::Attribs attribs;
    float t;
    if (CurveIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), attribs, t))
    {
        ReportHit(t, 0, attribs);
    }
}

[shader("closesthit")]
void curveClosestHit(inout RayData rayData, CurveIntersector::Attribs attribs)
{
    // Store hit information. Note we don't access the materials here.
    CurveHit curveHit;
    curveHit.instanceID = getGeometryInstanceID();
    curveHit.primitiveIndex = PrimitiveIndex();
    curveHit.barycentrics = attribs.barycentrics;

    // Write hit info to output buffer.
    uint2 launchIndex = DispatchRaysIndex().xy;
    gHemiVBufferRT.writeHit(launchIndex, WorldRayOrigin(), WorldRayDirection(), HitInfo(curveHit));
    rayData.t = RayTCurrent();
}


//
// Shader entry points for SDFGrid hit groups.
//

[shader("intersection")]
void sdfGridIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    SDFGridHitData sdfGridHitData;
    float t;
    if (SDFGridIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), sdfGridHitData, t))
    {
        ReportHit(t, 0, sdfGridHitData);
    }
}

[shader("closesthit")]
void sdfGridClosestHit(inout RayData rayData, SDFGridHitData sdfGridHitData)
{
    // Store hit information. Note we don't access the materials here.
    SDFGridHit sdfGridHit;
    sdfGridHit.instanceID = getGeometryInstanceID();
    sdfGridHit.hitData = sdfGridHitData;

    // Write hit info to output buffer.
    uint2 launchIndex = DispatchRaysIndex().xy;
    gHemiVBufferRT.writeHit(launchIndex, WorldRayOrigin(), WorldRayDirection(), HitInfo(sdfGridHit));
    rayData.t = RayTCurrent();
}

//
// Shader entry point for ray generation shader.
//

static float3 hemiDirFromPixel(uint2 pix, uint2 res, float3 n)
{
    float2 uv = (float2(pix) + 0.5) / float2(res);
    float3 local = sample_hemisphere_preserve_area(uv);
    float3 bitangent = perp_stark_onb(n);
    float3 tangent = cross(bitangent, n);
    return normalize(tangent*local.x + bitangent*local.y + n*local.z);
}

/**
 * Setup ShadingData based on loaded vertex/material attributes for a hit point.
 * @param[in] hit Hit information.
 * @param[in] rayOrigin Ray origin.
 * @param[in] rayDir Normalized ray direction.
 * @return ShadingData struct.
 */
ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir)
{
    VertexData v = {};
    uint materialID = {};

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        v = gScene.getVertexData(triangleHit);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();
        v = gScene.getVertexData(displacedTriangleHit, -rayDir);
        materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit curveHit = hit.getCurveHit();
        v = gScene.getVertexDataFromCurve(curveHit);
        materialID = gScene.getMaterialID(curveHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
    if (hit.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sdfGridHit = hit.getSDFGridHit();
        v = gScene.getVertexDataFromSDFGrid(sdfGridHit, rayOrigin, rayDir);
        materialID = gScene.getMaterialID(sdfGridHit.instanceID);
    }
#endif

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir);

    return sd;
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;

    GpuTimer timer;
    gHemiVBufferRT.beginTime(timer);

    // Trace ray
    // const Ray ray = gHemiVBufferRT.generateRay(launchIndex);

    // Build hemisphere direction aligned with the provided normal
    const uint2 dims = DispatchRaysDimensions().xy;

    //
    // Laser Hit Point
    //
    const HitInfo laserhit = HitInfo(gLaserVBuffer[uint2(0,0)]);
    const float4 laserViewW = gLaserViewW[uint2(0,0)];
    const float laserT = laserViewW.w;
    
    ShadingData laserHitSd = loadShadingData(laserhit, gHemi.gLaserOrigin, gHemi.gLaserDirection);
    const float3 laserHitPoint = laserHitSd.computeRayOrigin();
    const float3 laserHitPointN = laserHitSd.getOrientedFaceNormal();

    float3 Ng = normalize(laserHitPointN);
    float3 hemiDir = hemiDirFromPixel(launchIndex, dims, Ng);

    // Start slightly off the surface to avoid self hit
    Ray ray = Ray(laserHitPoint, hemiDir, 1e-4, 1e27f);

    RayData rayData;
    rayData.t = 0.0;
    TraceRay(
        gScene.rtAccel,
        HemiVBufferRT::kRayFlags,
        0xff /* instanceInclusionMask */,
        0 /* hitIdx */,
        getRayTypeCount(),
        0 /* missIdx */,
        ray.toRayDesc(),
        rayData
    );

    gHemiVBufferRT.writeAux(launchIndex, ray, rayData.t);

    gHemiVBufferRT.endTime(launchIndex, timer);
}
