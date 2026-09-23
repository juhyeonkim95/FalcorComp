// Ellipsoidal sampling of x -> y -> light (time-gated path tracer and ReSTIR).
// y is sampled on the ellipsoid with foci x and the light endpoint whose length
// |x - y| + |y - light| matches the time gate. It competes with the BSDF technique
// (BSDF-sample x -> y, then connect y to the light) for the same paths.
//
//   sampleEllipsoid()           samples the x -> y segment of the ellipsoidal technique.
//   evalBsdfTechniqueWeight()   weighs a BSDF-technique path at y against ellipsoidal sampling.
//
// Both take the camera path length ending at x (prefixLength) and the full-path gate
// center; the ellipse length is centered at gateCenter - prefixLength - light.laserT.
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Transient.TransientUtils;
import Utils.Transient.Ellipsoid;
import Utils.Transient.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Scene.RaytracingInline;
import RenderPasses.Shared.Utils.LoadShadingData;
import RenderPasses.Shared.Lights.LaserLightSampler;

// The x -> y segment of the ellipsoidal technique.
struct EllipsoidalSample
{
    HitInfo hit;          // Hit at y.
    ShadingData surface;  // Shading data at y.
    float3 direction;     // Unit x -> y.
    float distance;       // |y - x|.
    float pdf;            // Solid-angle density of direction at x.
};

// What the walk records at x when it BSDF-samples x -> y. At y it decides how the
// resulting BSDF-technique path is weighed against ellipsoidal sampling from x.
struct ScatterRecord
{
    float3 posW;             // x.
    float3 normalW;          // Oriented face normal at x.
    float pathLength;        // Camera path length ending at x.
    bool ellipsoidEligible;  // Whether x ran the ellipsoidal technique.
    float bsdfPdf;           // Solid-angle density of the BSDF sample x -> y.
    bool isDelta;            // The BSDF sample was a delta lobe.
};

float finitePositivePdf(float pdf)
{
    return pdf > 0.f && !isinf(pdf) && !isnan(pdf) ? pdf : 0.f;
}

float balanceWeight(float sampledPdf, float otherPdf)
{
    sampledPdf = finitePositivePdf(sampledPdf);
    otherPdf = finitePositivePdf(otherPdf);
    float scale = max(sampledPdf, otherPdf);
    if (scale == 0.f) return 0.f;
    // Scaling prevents overflow in the denominator for large densities.
    return (sampledPdf / scale) / (sampledPdf / scale + otherPdf / scale);
}

// Use the same regularized Jacobian for contribution evaluation and both MIS PDFs.
float solidAngleToArea(float3 from, float3 to, float3 normalAtTo)
{
    float3 segment = to - from;
    float segmentSquared = dot(segment, segment);
    if (!(segmentSquared > 0.f)) return 0.f;
    float3 direction = segment / sqrt(segmentSquared);
    float distanceSquared = max(segmentSquared, FLT_MIN);
    float cosine = max(abs(dot(normalAtTo, -direction)), FLT_MIN);
    return cosine / distanceSquared;
}

// Convert to solid angle using the reciprocal of the same clamped Jacobian.
float areaPdfToSolidAngle(float areaPdf, float3 from, float3 to, float3 normalAtTo)
{
    // Preserve genuine zero probability (e.g. the excluded NLOS backwall).
    if (!(areaPdf > 0.f)) return 0.f;
    float areaJacobian = solidAngleToArea(from, to, normalAtTo);
    if (!(areaJacobian > 0.f)) return 0.f;
    return finitePositivePdf(areaPdf / areaJacobian);
}

uint getCollectionTriangleIndex(HitInfo hit)
{
    if (hit.getType() != HitType::Triangle) return LightCollection::kInvalidIndex;
    TriangleHit triangleHit = hit.getTriangleHit();
    return gScene.triCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
}

bool supportsEllipsoidTriangle(Ellipsoid ellipse, EmissiveTriangle triangle)
{
    // Share the focus-on-plane rejection between sampling and PDF reconstruction.
    float3 toFirst = triangle.posW[0] - ellipse.p1;
    float3 toSecond = triangle.posW[0] - ellipse.p2;
    if (dot(toFirst, toFirst) == 0.f || dot(toSecond, toSecond) == 0.f) return false;
    return abs(dot(triangle.normal, normalize(toFirst))) >= 1e-4 &&
           abs(dot(triangle.normal, normalize(toSecond))) >= 1e-4;
}

// Sample the x -> y segment. The closest hit must be the sampled triangle; any
// intervening surface (or a miss) rejects the sample. y -> light is not traced.
// Consumes the length, triangle, and two point dimensions of rng, in that order.
bool sampleEllipsoid(ShadingData x, float prefixLength, LightSample light, float gateCenter,
    EmissiveLightSampler sampler, inout SampleGenerator rng, out EllipsoidalSample sample)
{
    sample = {};
    float sampledLength, lengthPdf;
    samplePathLength(gateCenter - (prefixLength + light.laserT), sampleNext1D(rng), sampledLength, lengthPdf);
    if (!(lengthPdf > 0.f)) return false;
    Ellipsoid ellipse;
    if (!buildEllipsoidFromFoci(x.posW, light.posW(), sampledLength,
        x.getOrientedFaceNormal(), light.getOrientedFaceNormal(), ellipse)) return false;
    uint triangleIndex;
    float trianglePdf;
    if (!sampler.sampleTriangleEllipsoid(ellipse, rng, triangleIndex, trianglePdf)) return false;
    if (triangleIndex >= gScene.triCollection.getTriangleCount()) return false;
    EmissiveTriangle triangle = gScene.triCollection.getTriangle(triangleIndex);
    if (!supportsEllipsoidTriangle(ellipse, triangle)) return false;
    SampleResultArea ellipseSample = sampleOnTriangleEllipsoid(ellipse,
        triangle.posW[0], triangle.posW[1], triangle.posW[2], sampleNext1D(rng), sampleNext1D(rng));
    if (!ellipseSample.ok) return false;
    float areaPdf = finitePositivePdf(lengthPdf * trianglePdf * ellipseSample.pdfA);
    if (!(areaPdf > 0.f)) return false;

    float3 segment = ellipseSample.p - x.posW;
    if (!(dot(segment, segment) > 0.f)) return false;
    sample.direction = normalize(segment);
    float3 rayOrigin = x.computeRayOrigin(dot(x.getOrientedFaceNormal(), sample.direction) >= 0.f);
    float3 visibilitySegment = ellipseSample.p - rayOrigin;
    if (!(dot(visibilitySegment, segment) > 0.f)) return false;
    SceneRayQuery<USE_ALPHA_TEST> query;
    float hitDistance;
    sample.hit = query.traceRay(Ray(rayOrigin, normalize(visibilitySegment), 0.f, FLT_MAX), hitDistance);
    if (getCollectionTriangleIndex(sample.hit) != triangleIndex) return false;
    sample.surface = loadShadingData(sample.hit, rayOrigin, sample.direction);
    sample.distance = length(sample.surface.posW - x.posW);
    sample.pdf = areaPdfToSolidAngle(areaPdf, x.posW, sample.surface.posW,
        sample.surface.getOrientedFaceNormal());
    return sample.pdf > 0.f;
}

// Solid-angle density with which sampleEllipsoid() at x would have produced y.
float evalEllipsoidPdf(ScatterRecord x, ShadingData y, HitInfo yHit, LightSample light,
    float gateCenter, EmissiveLightSampler sampler)
{
    float connectionLength = length(y.posW - x.posW) + length(y.posW - light.posW());
    Ellipsoid ellipse;
    if (!buildEllipsoidFromFoci(x.posW, light.posW(), connectionLength,
        x.normalW, light.getOrientedFaceNormal(), ellipse)) return 0.f;

    uint triangleIndex = getCollectionTriangleIndex(yHit);
    if (triangleIndex >= gScene.triCollection.getTriangleCount()) return 0.f;
    EmissiveTriangle triangle = gScene.triCollection.getTriangle(triangleIndex);
    if (!supportsEllipsoidTriangle(ellipse, triangle)) return 0.f;

    TriangleLightHit triangleHit;
    triangleHit.triangleIndex = triangleIndex;
    triangleHit.posW = y.posW;
    triangleHit.normalW = y.getOrientedFaceNormal();
    float trianglePdf = sampler.evalPdfEllipsoid(ellipse, triangleHit);
    if (!(trianglePdf > 0.f)) return 0.f;
    float lengthPdf = evalPdfPathLength(ellipse.t, gateCenter - (x.pathLength + light.laserT));
    if (!(lengthPdf > 0.f)) return 0.f;
    float areaFactor = evalTriangleEllipsoidPdf(
        ellipse, triangle.posW[0], triangle.posW[1], triangle.posW[2], y.posW);
    float ellipseAreaPdf = finitePositivePdf(lengthPdf * trianglePdf * areaFactor);
    return areaPdfToSolidAngle(ellipseAreaPdf, ellipse.p1, y.posW, y.getOrientedFaceNormal());
}

// Weight of a BSDF-technique path x -> y -> light, evaluated at y.
// With MIS: balance heuristic against the ellipse density. Without MIS, the
// ellipsoidal technique owns every path it can generate, so the BSDF technique
// keeps only paths outside ellipse support (e.g. excluded large triangles).
float evalBsdfTechniqueWeight(ScatterRecord x, ShadingData y, HitInfo yHit, LightSample light,
    float gateCenter, EmissiveLightSampler sampler, bool useMIS)
{
    // Delta arrivals cannot be generated by continuous ellipsoid sampling.
    if (!light.valid || x.isDelta || !x.ellipsoidEligible) return 1.f;
    float ellipsePdf = evalEllipsoidPdf(x, y, yHit, light, gateCenter, sampler);
    if (useMIS) return balanceWeight(x.bsdfPdf, ellipsePdf);
    return ellipsePdf > 0.f ? 0.f : 1.f;
}
