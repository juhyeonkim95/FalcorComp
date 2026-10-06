#include "Scene/SceneDefines.slangh"
__exported import Scene.Shading;

/**
 * Vertex data and material ID of a hit point.
 * @param[in] hit Hit information.
 * @param[in] rayOrigin Origin of the ray that found the hit: SDF-grid hits lie along it.
 * @param[in] rayDir Normalized direction of that ray.
 * @param[out] materialID Material ID.
 * @return VertexData struct.
 */
VertexData loadHitVertexData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, out uint materialID)
{
    VertexData v = {};
    materialID = {};

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

    return v;
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
    uint materialID;
    VertexData v = loadHitVertexData(hit, rayOrigin, rayDir, materialID);
    return gScene.materials.prepareShadingData(v, materialID, -rayDir);
}

/**
 * ShadingData of a hit found along one ray and seen along another direction, e.g. a point found by a ray from a
 * light or projector, shaded for the path vertex that sees it.
 * @param[in] hit Hit information.
 * @param[in] rayOrigin Origin of the ray that found the hit.
 * @param[in] rayDir Normalized direction of that ray.
 * @param[in] viewDir Normalized direction from the viewer to the hit point.
 * @return ShadingData struct.
 */
ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const float3 viewDir)
{
    uint materialID;
    VertexData v = loadHitVertexData(hit, rayOrigin, rayDir, materialID);
    return gScene.materials.prepareShadingData(v, materialID, -viewDir);
}

/**
 * Same as loadShadingData for a triangle hit whose vertex data v is already loaded.
 */
ShadingData loadShadingData(const TriangleHit hit, const VertexData v, const float3 rayDir)
{
    return gScene.materials.prepareShadingData(v, gScene.getMaterialID(hit.instanceID), -rayDir);
}

