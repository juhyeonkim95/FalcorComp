#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Transient.Ellipsoid;
import Utils.Transient.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Scene.RaytracingInline;
import Reservoirs;
import LoadShadingData;
import LaserLightSampler;


cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gRandomSeed;    // Frame count since scene was loaded.

    uint gPRNGDimension; // First available PRNG dimension.
    uint samplesPerPixel;
    uint2 gLaserHitVBufferRes;
    float specularRoughnessThreshold;
    float specularRoughnessThresholdEllipsoid;
    // Unused legacy bindings retained until the C++ binding cleanup.
    float gTemporalHistoryLength;
    float gRoughTimeGateSampleRatio;
}

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
    float3 laserPrevOrigin;
    float3 laserPrevDirection;
}


// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float2> gMotionVector; // Optional
Texture2D<PackedHitInfo> gTemporalVBuffer;


// Laser V Buffer (1 pixel)
Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW;

// Laser Hit V Buffer (256 x 256)
Texture2D<PackedHitInfo> gLaserHitVBuffer;
Texture2D<float4> gLaserHitViewW;
Texture2D<float> gLaserHitDepth;

// Reservoir Struct
StructuredBuffer<Reservoir> prevReservoirs;
RWStructuredBuffer<Reservoir> currReservoirs;

// Outputs
RWTexture2D<float4> gOutputColor;

EmissiveLightSampler emissiveSampler;

static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

// Offset each surface endpoint toward the open segment. The point-light endpoint
// has no surface to offset. BSDFs and path lengths still use unmodified positions.
bool traceVisibilityRay(ShadingData surface, LightSample light)
{
    float3 segment = light.posW() - surface.posW;
    if (!(dot(segment, segment) > 0.f)) return false;
    float3 origin = surface.computeRayOrigin(dot(surface.getOrientedFaceNormal(), segment) >= 0.f);
    float3 endpoint = light.posW();
#if IS_LIGHT_SOURCE_LASER
    endpoint = light.sd.computeRayOrigin(dot(light.getOrientedFaceNormal(), -segment) >= 0.f);
#endif
    float3 offsetSegment = endpoint - origin;
    if (!(dot(offsetSegment, segment) > 0.f)) return false;
    float distance = length(offsetSegment);
    SceneRayQuery<USE_ALPHA_TEST> query;
    return query.traceVisibilityRay(Ray(origin, offsetSegment / distance, 0.f, distance));
}

float3 getPrimaryRayDir(uint2 pixel, uint2 frameDim)
{
#if is_valid_gViewW
    return -gViewW[pixel].xyz;
#else
    return gScene.camera.computeRayPinhole(pixel, frameDim).dir;
#endif
}

float shadingCosine(ShadingData surface, IMaterialInstance material, float3 direction)
{
    return abs(dot(material.getProperties(surface).guideNormal, direction));
}

// camera -> ... -> a -> x -> y -> z -> ... -> light.
// During light evaluation, postBounce is 0 at x, 1 at y, 2 at z, etc.
// At the next iteration's BSDF sample it is already incremented: 2 means y->z.
struct ReconnectionState
{
    HitInfo xHit;
    HitInfo yHit;
    float3 incomingDirectionAtY;
    uint bounce;
    uint postBounce;
    uint prefixSeed;
    uint suffixSeed;
    float areaPdf;              // p_A(a->x), then p_A(a->x) * p_A(x->y).
    float3 suffixThroughput;    // cosine_y/pdf_y, then sampled weights at z and beyond.
    float suffixLength;        // y->...->current surface; excludes current->light.

    [mutating]
    void recordHit(HitInfo hit, ShadingData surface, BSDFSample sample, uint depth,
        bool eligible, float segmentLength, float suffixDirectionWeight, uint sampleSeed)
    {
        float opticalLength = segmentLength * surface.IoR;
        if (bounce == 0)
        {
            if (eligible)
            {
                bounce = depth;
                xHit = hit;
                float cosine = max(dot(surface.getOrientedFaceNormal(), -sample.wo), 0.f);
                areaPdf = sample.pdf * cosine / max(segmentLength * segmentLength, kMinLightDistSqr);
            }
        }
        else if (postBounce == 1)
        {
            yHit = hit;
            float cosine = max(dot(surface.getOrientedFaceNormal(), -sample.wo), 0.f);
            areaPdf *= sample.pdf * cosine / max(segmentLength * segmentLength, kMinLightDistSqr);
        }
        else if (postBounce == 2)
        {
            incomingDirectionAtY = -sample.wo;
            suffixSeed = sampleSeed;
            suffixThroughput *= suffixDirectionWeight;
            suffixLength += opticalLength;
        }
        else
        {
            suffixThroughput *= sample.weight;
            suffixLength += opticalLength;
        }
    }
};

struct DirectConnection
{
    float3 direction;
    float3 bsdfCosine;
    float3 incidentRadiance;
    float distance;
    float totalLength;
    float gate;
};

DirectConnection evaluateDirectConnection(ShadingData surface, IMaterialInstance material,
    LightSample light, float pathLength, inout SampleGenerator rng)
{
    DirectConnection connection = {};
    if (!light.valid) return connection;
    float3 segment = light.posW() - surface.posW;
    connection.distance = length(segment);
    connection.totalLength = pathLength + connection.distance + light.laserT;
    if (!(connection.distance > 0.f)) return connection;
    connection.direction = segment / connection.distance;
    bool visible = traceVisibilityRay(surface, light);
    connection.bsdfCosine = material.eval(surface, connection.direction, rng);
    connection.incidentRadiance = light.evalLi(surface.posW, rng) * float(visible);
    connection.gate = pathLengthImportance(connection.totalLength, tcurr);
    return connection;
}

// Submit one completed-path candidate. Keep the Monte Carlo
// contribution, the area target, and the RIS selection weight distinct.
void submitCandidate(inout Reservoir reservoir, ReconnectionState rc,
    ShadingData surface, IMaterialInstance material, LightSample light,
    DirectConnection connection, float3 throughput, float techniqueWeight, uint lightSeed, inout SampleGenerator rng)
{
    float3 contribution = throughput * connection.bsdfCosine * connection.incidentRadiance * connection.gate;
    float3 target = rc.bounce > 0 ? contribution * rc.areaPdf : contribution;
    // The target is reconstructed by spatial reuse without a technique label.
    // MIS changes selection/W, never the stored physical target or suffix payload.
    float selectionWeight = luminance(contribution) * techniqueWeight / float(samplesPerPixel);
    if (!reservoir.update(target, selectionWeight, 1, rng)) return;

    reservoir.totalPathLength = connection.totalLength;
    reservoir.rcVertexBounce = rc.bounce;
    if (rc.bounce == 0) return; // Reconnection fields are unused for this local-only sample.

    reservoir.rcVertexHit = rc.xHit;
    reservoir.rcVertexBounce = rc.bounce;
    reservoir.initRandomSeed = rc.prefixSeed;
    reservoir.rcNextVertexBounce = rc.postBounce;
    if (rc.postBounce == 0)
    {
        // x->light: y is the light endpoint, not a BSDF-sampled surface.
        reservoir.rcNextVertexHit = light.hit;
        reservoir.rcNextVertexWi = light.dir;
        reservoir.rcNextVertexIrradiance = light.Li;
        reservoir.rcNextVertexPathLength = light.laserT;
    }
    else
    {
        reservoir.rcNextVertexHit = rc.yHit;
        reservoir.rcNextVertexPathLength = rc.suffixLength + connection.distance + light.laserT;
        if (rc.postBounce == 1)
        {
            // y->light: Q = cosine_y * Li, with no BSDF direction PDF.
            reservoir.rcNextVertexWi = -connection.direction;
            reservoir.rcNextVertexIrradiance = connection.incidentRadiance *
                shadingCosine(surface, material, connection.direction);
        }
        else
        {
            // y->z->...->light: Q = cosine_y/pdf_y * estimated Li(y, omega_yz).
            // Excludes y's BSDF, camera-prefix throughput, and the time gate.
            reservoir.rcNextVertexWi = rc.incomingDirectionAtY;
            reservoir.rcNextVertexIrradiance = rc.suffixThroughput *
                connection.bsdfCosine * connection.incidentRadiance;
        }
    }
#if IS_SCENE_DYNAMIC
    reservoir.rcNextVertexRandomSeed = rc.suffixSeed;
    reservoir.lightRandomSeed = lightSeed;
#endif
}

#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
// State at x needed when the BSDF walk reaches y one iteration later.
struct DeferredConnection
{
    float3 posW;
    float3 normalW;
    float pathLength;
    float bsdfPdf;
    bool delta;
    bool ellipsoidEligible;
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

// Reconstruct p_omega(x -> y) for an actual BSDF hit. prefixWithLaser is the camera prefix
// ending at x plus the laser-to-light-endpoint distance; it excludes x -> y -> light.
float evalEllipsoidPdf(Ellipsoid ellipse, HitInfo hit, ShadingData target, float prefixWithLaser)
{
    uint triangleIndex = getCollectionTriangleIndex(hit);
    if (triangleIndex >= gScene.triCollection.getTriangleCount()) return 0.f;
    EmissiveTriangle triangle = gScene.triCollection.getTriangle(triangleIndex);
    if (!supportsEllipsoidTriangle(ellipse, triangle)) return 0.f;

    TriangleLightHit triangleHit;
    triangleHit.triangleIndex = triangleIndex;
    triangleHit.posW = target.posW;
    triangleHit.normalW = target.getOrientedFaceNormal();
    float trianglePdf = emissiveSampler.evalPdfEllipsoid(ellipse, triangleHit);
    if (!(trianglePdf > 0.f)) return 0.f;
    float lengthPdf = evalPdfPathLength(ellipse.t, tcurr - prefixWithLaser);
    if (!(lengthPdf > 0.f)) return 0.f;
    float areaFactor = evalTriangleEllipsoidPdf(
        ellipse, triangle.posW[0], triangle.posW[1], triangle.posW[2], target.posW);
    float ellipseAreaPdf = finitePositivePdf(lengthPdf * trianglePdf * areaFactor);
    return areaPdfToSolidAngle(ellipseAreaPdf, ellipse.p1, target.posW, target.getOrientedFaceNormal());
}

// Evaluate the competing ellipse density when the BSDF walk arrives one step later.
float deferredDirectWeight(DeferredConnection previous, ShadingData target, HitInfo hit, LightSample light)
{
    if (!light.valid || previous.delta || !previous.ellipsoidEligible) return 1.f;
    float ellipsePdf = 0.f;
    float connectionLength = length(target.posW - previous.posW) + length(target.posW - light.posW());
    Ellipsoid ellipse;
    if (buildEllipsoidFromFoci(previous.posW, light.posW(), connectionLength,
        previous.normalW, light.getOrientedFaceNormal(), ellipse))
        ellipsePdf = evalEllipsoidPdf(ellipse, hit, target, previous.pathLength + light.laserT);
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
    return balanceWeight(previous.bsdfPdf, ellipsePdf);
#else
    // Preserve direct paths outside ellipse support (e.g. excluded large triangles).
    return ellipsePdf > 0.f ? 0.f : 1.f;
#endif
}

// A terminal ellipse branch inserts one surface, leaving the replayable BSDF walk
// and its RNG untouched. recordHit removes the ACTUAL proposal density at a->x
// or x->y; after y it instead stores cosine_y / ellipsePdf in the suffix payload.
void submitEllipsoidalCandidate(inout Reservoir reservoir, ReconnectionState rc,
    ShadingData origin, IMaterialInstance material, LightSample light, float prefixLength,
    float3 throughput, uint targetDepth, uint lightSeed, inout SampleGenerator rng)
{
    if (!light.valid) return;
    float sampledLength, lengthPdf;
    samplePathLength(tcurr - prefixLength - light.laserT, sampleNext1D(rng), sampledLength, lengthPdf);
    if (!(lengthPdf > 0.f)) return;
    Ellipsoid ellipse;
    if (!buildEllipsoidFromFoci(origin.posW, light.posW(), sampledLength,
        origin.getOrientedFaceNormal(), light.getOrientedFaceNormal(), ellipse)) return;
    uint triangleIndex;
    float trianglePdf;
    if (!emissiveSampler.sampleTriangleEllipsoid(ellipse, rng, triangleIndex, trianglePdf)) return;
    if (triangleIndex >= gScene.triCollection.getTriangleCount()) return;
    EmissiveTriangle triangle = gScene.triCollection.getTriangle(triangleIndex);
    if (!supportsEllipsoidTriangle(ellipse, triangle)) return;
    SampleResultArea ellipseSample = sampleOnTriangleEllipsoid(ellipse,
        triangle.posW[0], triangle.posW[1], triangle.posW[2], sampleNext1D(rng), sampleNext1D(rng));
    if (!ellipseSample.ok) return;
    float areaPdf = finitePositivePdf(lengthPdf * trianglePdf * ellipseSample.pdfA);
    if (!(areaPdf > 0.f)) return;

    float3 segment = ellipseSample.p - origin.posW;
    if (!(dot(segment, segment) > 0.f)) return;
    float3 direction = normalize(segment);
    float3 rayOrigin = origin.computeRayOrigin(dot(origin.getOrientedFaceNormal(), direction) >= 0.f);
    float3 visibilitySegment = ellipseSample.p - rayOrigin;
    if (!(dot(visibilitySegment, segment) > 0.f)) return;
    SceneRayQuery<USE_ALPHA_TEST> query;
    float hitDistance;
    HitInfo hit = query.traceRay(Ray(rayOrigin, normalize(visibilitySegment), 0.f, FLT_MAX), hitDistance);
    if (!hit.isValid()) return;
    if (getCollectionTriangleIndex(hit) != triangleIndex) return;
    ShadingData target = loadShadingData(hit, rayOrigin, direction);
    let targetMaterial = gScene.materials.getMaterialInstance(target, ExplicitLodTextureSampler(0.f));
    float segmentLength = length(target.posW - origin.posW);
    float targetLength = prefixLength + segmentLength * target.IoR;
    if (!(targetLength < getMaxpathLength(tcurr) + 1e-2f)) return;
    float ellipsePdf = areaPdfToSolidAngle(areaPdf, origin.posW, target.posW, target.getOrientedFaceNormal());
    if (!(ellipsePdf > 0.f)) return;
    float techniqueWeight = 1.f;
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
    float directPdf = material.evalPdf(origin, direction, kUseImportanceSampling);
    techniqueWeight = balanceWeight(ellipsePdf, directPdf);
#endif
    BSDFSample proposal = {};
    proposal.wo = direction;
    proposal.pdf = ellipsePdf;
    proposal.weight = material.eval(origin, direction, rng) / ellipsePdf;
    bool eligible = material.getProperties(origin).roughness > specularRoughnessThreshold &&
        targetMaterial.getProperties(target).roughness > specularRoughnessThreshold;
    float suffixDirectionWeight = 0.f;
    if (rc.postBounce == 2) suffixDirectionWeight = shadingCosine(origin, material, direction) / ellipsePdf;
    rc.recordHit(hit, target, proposal, targetDepth, eligible, segmentLength, suffixDirectionWeight, 0);
    DirectConnection connection = evaluateDirectConnection(target, targetMaterial, light, targetLength, rng);
    submitCandidate(reservoir, rc, target, targetMaterial, light, connection,
        throughput * proposal.weight, techniqueWeight, lightSeed, rng);
}

#endif

// Generate initial RIS candidates by BSDF walking and connecting each secondary
// surface to the single point/laser light. Primary direct lighting stays excluded.
float3 tracePath(uint2 pixel, uint2 frameDim)
{
    uint index = pixel.y * frameDim.x + pixel.x;
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    float3 primaryDirection = getPrimaryRayDir(pixel, frameDim);
    Reservoir reservoir = Reservoir();
    if (!primaryHit.isValid())
    {
        currReservoirs[index] = reservoir;
        return kUseEnvBackground ? gScene.envMap.eval(primaryDirection) : float3(0.f);
    }

    float3 cameraPosition = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraPosition, primaryDirection);
    let primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float primaryLength = length(primary.posW - cameraPosition);
    float maxPathLength = getMaxpathLength(tcurr);
    LaserLightSampler lightSampler = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);
    // Preserve separate streams so prefix replay never consumes reservoir/light RNG draws.
    SampleGenerator rng = SampleGenerator(pixel, gFrameCount);
    SampleGenerator bsdfRng = SampleGenerator(pixel, gFrameCount + 151);
    SampleGenerator lightRng = SampleGenerator(pixel, gFrameCount + 5713);

    for (uint sampleIndex = 0; sampleIndex < samplesPerPixel; ++sampleIndex)
    {
        ShadingData surface = primary;
        IMaterialInstance material = primaryMaterial;
        float3 throughput = 1.f;
        float pathLength = primaryLength;
        ReconnectionState rc = {};
        rc.xHit = makeInvalidHit();
        rc.yHit = makeInvalidHit();
        rc.areaPdf = 1.f;
        rc.suffixThroughput = 1.f;
        rc.prefixSeed = bsdfRng.getCurrentSeed();

        for (uint depth = 1; depth < MAX_BOUNCES; ++depth)
        {
            if (!any(throughput > 0.f)) break;
            if (!(pathLength < maxPathLength)) break;
#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
            DeferredConnection previous = {};
            previous.posW = surface.posW;
            previous.normalW = surface.getOrientedFaceNormal();
            previous.pathLength = pathLength;
            previous.ellipsoidEligible = (material.getLobeTypes(surface) & uint(LobeType::NonDelta)) != 0;
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
            previous.ellipsoidEligible = previous.ellipsoidEligible &&
                material.getProperties(surface).roughness > specularRoughnessThresholdEllipsoid;
#endif
            if (previous.ellipsoidEligible)
            {
                LightSample ellipseLight = {};
                uint ellipseLightSeed = lightRng.getCurrentSeed();
                lightSampler.generateLightSample(lightRng, ellipseLight);
                submitEllipsoidalCandidate(reservoir, rc, surface, material, ellipseLight,
                    pathLength, throughput, depth, ellipseLightSeed, rng);
            }
#endif
            bool previousDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            uint sampleSeed = bsdfRng.getCurrentSeed();
            BSDFSample sample = {};
            if (!material.sample(surface, bsdfRng, sample, kUseImportanceSampling)) break;
#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
            previous.bsdfPdf = sample.pdf;
            previous.delta = sample.isLobe(LobeType::Delta);
#endif
            throughput *= sample.weight;
            if (!any(throughput > 0.f)) break;

            // Capture at y before replacing its shading state with the hit at z.
            float suffixDirectionWeight = 0.f;
            if (rc.postBounce == 2)
            {
                if (sample.pdf > 0.f)
                    suffixDirectionWeight = shadingCosine(surface, material, sample.wo) / sample.pdf;
            }
            float3 previousPosition = surface.posW;
            float3 origin = surface.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
            SceneRayQuery<USE_ALPHA_TEST> query;
            float hitT;
            HitInfo hit = query.traceRay(Ray(origin, sample.wo, 0.f, FLT_MAX), hitT);
            if (!hit.isValid()) break;
            surface = loadShadingData(hit, origin, sample.wo);
            material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            float segmentLength = length(surface.posW - previousPosition);
            pathLength += segmentLength * surface.IoR;
            // Preserve the existing cutoff margin, but measure the physical path
            // instead of distance from an offset ray origin. No sentinel length.
            if (!(pathLength < maxPathLength + 1e-2f)) break;
            bool currentDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            rc.recordHit(hit, surface, sample, depth, previousDiffuse && currentDiffuse && segmentLength > 0.f,
                segmentLength, suffixDirectionWeight, sampleSeed);

            LightSample light = {};
            uint lightSeed = lightRng.getCurrentSeed();
            lightSampler.generateLightSample(lightRng, light);
            DirectConnection connection = evaluateDirectConnection(surface, material, light, pathLength, rng);
            float techniqueWeight = 1.f;
#if LIGHT_SAMPLING_METHOD != DIRECT_CONNECTION
            techniqueWeight = deferredDirectWeight(previous, surface, hit, light);
#endif
            submitCandidate(reservoir, rc, surface, material, light, connection, throughput, techniqueWeight, lightSeed, rng);
            if (rc.bounce > 0) ++rc.postBounce;
        }
    }
    float target = luminance(reservoir.f);
    reservoir.W = target > 0.f ? reservoir.wSum / target : 0.f;
    currReservoirs[index] = reservoir;
    return reservoir.W * reservoir.f;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] = float4(tracePath(pixel, gFrameDim) / time_gate_window, 1.f);
}
