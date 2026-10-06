/** Picks the scene triangle that holds the vertex y of an ellipsoidal connection, and evaluates the probability of
    that pick (host: EllipsoidalTriangleSampler in Shared/Host/Configs/EllipsoidalSamplingConfig.h).

    ELLIPSOID_TRIANGLE_SAMPLER selects the method:
    - ELLIPSOID_TRIANGLE_SAMPLER_UNIFORM: uniformly over the active triangles of gSceneTriangles.
    - ELLIPSOID_TRIANGLE_SAMPLER_BVH: by descending gSceneTriangleBVH, a light BVH over gSceneTriangles (one triangle
      per leaf), choosing each child in proportion to its flux (the area of its triangles) when its bounds can meet
      the ellipsoid, 0 otherwise. The probability of a triangle is the product of the choices on its path.
*/
#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.SampleGeneratorInterface;
import Rendering.Lights.LightBVH;
import RenderPasses.Shared.Shaders.Geometry.Ellipsoid;
__exported import RenderPasses.Shared.Shaders.Lights.SceneTriangles;

#define ELLIPSOID_TRIANGLE_SAMPLER_UNIFORM 0
#define ELLIPSOID_TRIANGLE_SAMPLER_BVH 1
#ifndef ELLIPSOID_TRIANGLE_SAMPLER
#define ELLIPSOID_TRIANGLE_SAMPLER ELLIPSOID_TRIANGLE_SAMPLER_BVH
#endif

LightBVH gSceneTriangleBVH; // ELLIPSOID_TRIANGLE_SAMPLER_BVH only.

/// Importance of a BVH node for ellipsoid E: its flux if its bounds can meet E, 0 otherwise.
float computeEllipsoidNodeImportance(const Ellipsoid E, const uint nodeIndex)
{
    const SharedNodeAttributes nodeAttribs = gSceneTriangleBVH.getNodeAttributes(nodeIndex);
    return nodeAttribs.flux * float(isAABBValidForEllipoid(E, nodeAttribs.origin, nodeAttribs.extent));
}

/// Descends from the root to a leaf, choosing each child in proportion to its importance. Each level draws its own
/// random number: rescaling one number over the 20-40 levels of a BVH over every scene triangle would run out of its
/// 24 bits, making leaves below ~2^-24 unreachable. Returns the last level's number, rescaled, for the leaf.
bool traverseEllipsoidBVH<S : ISampleGenerator>(const Ellipsoid E, inout S sg, out float u, out float pdf, out uint nodeIndex)
{
    pdf = 1.0f;
    nodeIndex = 0;
    u = sampleNext1D(sg);
    bool isLeaf = gSceneTriangleBVH.isLeaf(nodeIndex);
    while (!isLeaf)
    {
        if (nodeIndex != 0) u = sampleNext1D(sg);
        uint leftNodeIndex = nodeIndex + 1;
        uint rightNodeIndex = gSceneTriangleBVH.getInternalNode(nodeIndex).rightChildIdx;

        float leftNodeImportance = computeEllipsoidNodeImportance(E, leftNodeIndex);
        float rightNodeImportance = computeEllipsoidNodeImportance(E, rightNodeIndex);
        float totalImportance = leftNodeImportance + rightNodeImportance;
        // Neither child can hold the ellipsoid.
        if (totalImportance == 0.f) return false;

        float pLeft = leftNodeImportance / totalImportance;
        float pRight = 1.0f - pLeft;
        if (u < pLeft)
        {
            u = u / pLeft; // Rescale to [0,1).
            pdf *= pLeft;
            nodeIndex = leftNodeIndex;
        }
        else
        {
            u = (u - pLeft) / pRight; // Rescale to [0,1).
            pdf *= pRight;
            nodeIndex = rightNodeIndex;
        }
        isLeaf = gSceneTriangleBVH.isLeaf(nodeIndex);
    }
    return true;
}

/// Probability with which traverseEllipsoidBVH() reaches the leaf that `bitmask` (the triangle's path) leads to.
float evalEllipsoidBVHTraversalPdf(const Ellipsoid E, uint64_t bitmask, out uint nodeIndex)
{
    float traversalPdf = 1.0f;
    nodeIndex = 0;
    bool isLeaf = gSceneTriangleBVH.isLeaf(nodeIndex);
    while (!isLeaf)
    {
        uint leftNodeIndex = nodeIndex + 1;
        uint rightNodeIndex = gSceneTriangleBVH.getInternalNode(nodeIndex).rightChildIdx;

        float leftNodeImportance = computeEllipsoidNodeImportance(E, leftNodeIndex);
        float rightNodeImportance = computeEllipsoidNodeImportance(E, rightNodeIndex);
        float totalImportance = leftNodeImportance + rightNodeImportance;
        if (totalImportance == 0.f) return 0.0f;

        float pLeft = leftNodeImportance / totalImportance;
        if ((bitmask & 0x1) == 0)
        {
            traversalPdf *= pLeft;
            nodeIndex = leftNodeIndex;
        }
        else
        {
            traversalPdf *= 1.0f - pLeft;
            nodeIndex = rightNodeIndex;
        }
        bitmask >>= 1;
        isLeaf = gSceneTriangleBVH.isLeaf(nodeIndex);
    }
    return traversalPdf;
}

/** Picks the triangle of an ellipsoidal connection for ellipsoid E.
    @param[in,out] sg Sample generator: one number per BVH level (BVH), or one 32-bit number (uniform).
    @param[out] triangleIndex Index in gSceneTriangles.
    @param[out] pdf Probability of the pick.
    @return False if no triangle can be picked.
*/
bool sampleEllipsoidTriangle<S : ISampleGenerator>(const Ellipsoid E, inout S sg, out uint triangleIndex, out float pdf)
{
    triangleIndex = LightCollection::kInvalidIndex;
    pdf = 0.f;
#if ELLIPSOID_TRIANGLE_SAMPLER == ELLIPSOID_TRIANGLE_SAMPLER_BVH
    float leafPdf;
    uint leafNodeIndex;
    float u;
    if (!traverseEllipsoidBVH(E, sg, u, leafPdf, leafNodeIndex)) return false;
    // Uniformly within the leaf (the host builds leaves of one triangle).
    const LeafNode node = gSceneTriangleBVH.getLeafNode(leafNodeIndex);
    uint idx = min((uint)(u * node.triangleCount), node.triangleCount - 1); // In case u == 1.
    triangleIndex = gSceneTriangleBVH.getNodeTriangleIndex(node, idx);
    pdf = leafPdf * (1.0f / (float)node.triangleCount);
    return true;
#else
    uint triangleCount = gSceneTriangles.getActiveTriangleCount();
    if (triangleCount == 0) return false;
    // A 32-bit random number scaled in integers: with a float u, u * count gives the indices counts that differ by
    // about count / 2^24 relatively, and some indices are unreachable past 2^24 triangles.
    uint idx = uint((uint64_t(sg.next()) * uint64_t(triangleCount)) >> 32);
    triangleIndex = gSceneTriangles.activeTriangles[idx];
    pdf = 1.f / (float)triangleCount;
    return true;
#endif
}

/// Probability with which sampleEllipsoidTriangle() picks triangle `triangleIndex` (of gSceneTriangles) for E.
float evalEllipsoidTrianglePdf(const Ellipsoid E, const uint triangleIndex)
{
    if (triangleIndex >= gSceneTriangles.getTriangleCount()) return 0.f;
#if ELLIPSOID_TRIANGLE_SAMPLER == ELLIPSOID_TRIANGLE_SAMPLER_BVH
    // The triangle's path through the BVH, as 2x32 bits (driver bug with uint64_t buffers, see LightBVHSampler). The
    // builder leaves an all-ones mask for triangles left out of the BVH (e.g. larger than the area cutoff).
    uint2 tmp = gSceneTriangleBVH.triangleBitmasks[triangleIndex];
    if (tmp.x == 0xffffffffu && tmp.y == 0xffffffffu) return 0.f;
    uint64_t bitmask = ((uint64_t)tmp.y << 32) | tmp.x;

    uint leafNodeIndex;
    float traversalPdf = evalEllipsoidBVHTraversalPdf(E, bitmask, leafNodeIndex);
    if (traversalPdf == 0.0f) return 0.0f;
    // Uniformly within the leaf; only its members can be picked.
    const LeafNode node = gSceneTriangleBVH.getLeafNode(leafNodeIndex);
    for (uint i = 0; i < node.triangleCount; ++i)
    {
        if (gSceneTriangleBVH.getNodeTriangleIndex(node, i) == triangleIndex)
            return traversalPdf * (1.0f / float(node.triangleCount));
    }
    return 0.f;
#else
    uint count = gSceneTriangles.getActiveTriangleCount();
    if (count == 0 || gSceneTriangles.getActiveTriangleIndex(triangleIndex) == LightCollection::kInvalidIndex) return 0.f;
    return 1.f / float(count);
#endif
}
