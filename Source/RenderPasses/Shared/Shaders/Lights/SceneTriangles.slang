/** Every triangle of the scene, as a light collection weighted by area instead of emitted flux (LightCollection with
    allTriangles; host: Shared/Host/SceneTriangles.h). It holds the vertices y of ellipsoidal connections and the
    triangles of THPT's single-bounce approximation. Triangle indices are the collection's, not the scene's.
*/
__exported import Scene.Lights.LightCollection;
import Scene.HitInfo;

// A ConstantBuffer, not a plain global: gfx's D3D12 root signature has no constant buffer for plain values at global
// scope (LightCollection holds its counts), so D3D12 would reject the pipeline (E_INVALIDARG) while Vulkan works.
ConstantBuffer<LightCollection> gSceneTriangles;

/// Index in gSceneTriangles of the triangle that `hit` landed on; LightCollection::kInvalidIndex for other geometry.
uint getSceneTriangleIndex(HitInfo hit)
{
    if (hit.getType() != HitType::Triangle) return LightCollection::kInvalidIndex;
    TriangleHit triangleHit = hit.getTriangleHit();
    return gSceneTriangles.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
}
