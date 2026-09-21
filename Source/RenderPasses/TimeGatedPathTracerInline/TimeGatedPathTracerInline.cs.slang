#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Transient.TransientUtils;
import Utils.Transient.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Utils.Transient.Ellipsoid;
import Scene.RaytracingInline;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // Host-bound interface field; dimension offset is not yet consumed.
    float specularRoughnessThreshold;

    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;

    uint samplesPerPixel;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Retained for the C++ render-pass bindings; connection sampling traces its own laser ray.
Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

EmissiveLightSampler emissiveSampler; // Triangle-selection hierarchy for ellipsoidal connections.

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const bool kUseAlphaTest = USE_ALPHA_TEST;

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;


// Surface endpoints are already offset away from their surfaces toward the connection.
bool traceVisibilityRay(const float3 origin, const float3 endpoint)
{
    float3 segment = endpoint - origin;
    float distance = length(segment);
    if (!(distance > 0.f) || isinf(distance)) return false;
    Ray visibilityRay = Ray(origin, segment / distance, 0.f, distance);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
{
    Ray ray = Ray(origin, dir, 0.0, kRayTMax);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceRay(ray, hitT);
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

/**
 * Returns the primary ray's direction.
 */
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[launchIndex].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
    }
}

/** Describes a light sample.
*/
struct LightSample
{
    bool valid;
    float laserT;
    float3 Li;
#if IS_LIGHT_SOURCE_LASER
    ShadingData sd;
    IMaterialInstance mi;
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = sd.posW - posW;
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        return Li * mi.eval(sd, normalize(posW - sd.posW), sg) / distSqr;
    }
    float3 getOrientedFaceNormal(){
        return sd.getOrientedFaceNormal();
    }
    float3 posW(){
        return sd.posW;
    }
#else
    float3 origin;
    float3 dir;
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = this.origin - posW;
        float inspot = float(dot(dir, toLight) < 0.0);
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        return Li / distSqr * inspot;
    }
    float3 getOrientedFaceNormal(){
        return dir;
    }
    float3 posW(){
        return origin;
    }
#endif
}

// Laser Sampling
struct LaserLightSampler
{
    float3 laserOrigin;
    float3 laserDirection;
    float laserCosAngle;
    float3 laserPower;

    // helper axis
    float3 laserTangent;
    float3 laserBitangent;

    __init(float3 laserOrigin, float3 laserDirection, float laserCosAngle, float3 laserPower){
        this.laserOrigin = laserOrigin;
        this.laserDirection = laserDirection;
        this.laserCosAngle = laserCosAngle;
        this.laserBitangent = perp_stark_onb(laserDirection);
        this.laserTangent = cross(laserBitangent, laserDirection);
        this.laserPower = laserPower;
    }

    void generateLightSample(
        inout SampleGenerator sg,
        out LightSample ls
    ) {
        ls = {};
        #if IS_LIGHT_SOURCE_LASER
            // (1) Collimated laser (trace additional ray from laser origin -> laser direction)
            float3 local = sample_cone(sampleNext2D(sg), this.laserCosAngle);
            float3 laser_d = normalize(this.laserTangent*local.x + this.laserBitangent*local.y + this.laserDirection*local.z);
            float laserT;
            Ray ray = Ray(this.laserOrigin, laser_d, 0.f, FLT_MAX);
            SceneRayQuery<kUseAlphaTest> sceneRayQuery;
            HitInfo laserHit = sceneRayQuery.traceRay(ray, laserT);
            if (!laserHit.isValid()) return;
            ls.sd = loadShadingData(laserHit, this.laserOrigin, laser_d);
            ls.mi = gScene.materials.getMaterialInstance(ls.sd, ExplicitLodTextureSampler(0.f));
            ls.laserT = laserT;
            ls.Li = laserPower;
        #else
            // (2) Point Light
            ls.dir = this.laserDirection;
            ls.laserT = 0.0;
            ls.origin = this.laserOrigin;
            ls.Li = laserPower;
        #endif
        ls.valid = true;
    }
}


// Trace camera paths and connect them to a sampled laser endpoint.
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 151);

        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        // Legacy laser-spot overlay; this is separate from the time-gated estimator.
        if(kComputeDirect)
        {
            float3 toLaserDir = normalize(laserOrigin - sd0.posW);
            float toLaserDist = length(laserOrigin - sd0.posW);
            float minCosAngle = min(laserCosAngle, 1.0-(1e-5));
            bool inspot = (dot(-toLaserDir, laserDirection) > minCosAngle);
            float3 L = mi0.eval(sd0, toLaserDir, sg) * laserPower / (toLaserDist * toLaserDist) * float(inspot);
            L = float3(L.x, 0.0, 0.0);
            outColor += samplesPerPixel * L;
        }

        float maxPathLength = getMaxpathLength(tcurr);
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);


        for(uint i=0; i<samplesPerPixel; i++){
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);

            //
            // (1) First Hit Material
            //
            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            BSDFSample bsdfSample = {};
            float pathLength = length(sd.posW - primaryRayOrigin);

            HitInfo hit = hit0;
            float hitT;

            // show direct?
            if(kComputeDirect){
                // sample light
                LightSample ls = {};
                lls.generateLightSample(sg, ls);
                result += throughput * evalDirectConnection(sd, ls, mi, pathLength, sg);
            }
#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid() && pathLength < maxPathLength; depth++){
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;

                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                float3 previousPosition = sd.posW;
                float3 rayOrigin = sd.computeRayOrigin(!is_transmission);
                float segmentIoR = sd.IoR;
                hit = traceRay(rayOrigin, bsdfSample.wo, hitT);

                if(hit.isValid() && any(throughput > 0.)){
                    sd = loadShadingData(hit, rayOrigin, bsdfSample.wo);
                    pathLength += length(sd.posW - previousPosition) * segmentIoR;
                    if (pathLength >= maxPathLength) break;
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    // sample light
                    LightSample ls = {};
                    lls.generateLightSample(sg, ls);
                    result += throughput * evalDirectConnection(sd, ls, mi, pathLength, sg);
                }
            }
#elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION || LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
            DeferredConnection previous = {};
            for (uint depth = 0; depth < kMaxBounces && pathLength < maxPathLength; ++depth)
            {
                bool hasNonDelta = (mi.getLobeTypes(sd) & uint(LobeType::NonDelta)) != 0;
                bool useEllipsoid = canSampleEllipsoid(depth, hasNonDelta);
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
                useEllipsoid = useEllipsoid && mi.getProperties(sd).roughness > specularRoughnessThreshold;
#endif
                LightSample ls = {};
                lls.generateLightSample(sg, ls);

                // At x, ellipsoidal sampling completes x -> y -> light immediately.
                if (useEllipsoid && ls.valid)
                {
                    EllipsoidalConnection connection = evalEllipsoidalConnection(sd, ls, mi, pathLength, sg);
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
                    float weight = balanceWeight(connection.ellipsePdf, connection.directPdf);
#else
                    float weight = 1.f;
#endif
                    result += throughput * weight * connection.radiance;
                }

                // At y, direct sampling completes the competing path begun at x.
                if (depth > 0 && hasNonDelta && ls.valid)
                {
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
                    float weight = evalDeferredDirectWeight(previous, sd, hit, ls);
                    result += throughput * weight * evalDirectConnection(sd, ls, mi, pathLength, sg);
#else
                    // Delta arrivals cannot be generated by continuous ellipsoid sampling.
                    if (!previous.ellipsoidEligible || previous.delta)
                        result += throughput * evalDirectConnection(sd, ls, mi, pathLength, sg);
#endif
                }

                if (depth + 1 >= kMaxBounces) break;
                previous.posW = sd.posW;
                previous.normalW = sd.getOrientedFaceNormal();
                previous.pathLength = pathLength;
                // Eligibility does not depend on whether the independent light/ellipse draw succeeded.
                previous.ellipsoidEligible = useEllipsoid;
                if (!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)) break;
                previous.delta = bsdfSample.isLobe(LobeType::Delta);
                previous.bsdfPdf = bsdfSample.pdf;
                throughput *= bsdfSample.weight;
                if (!any(throughput > 0.f) || any(throughput < 0.f) || any(isinf(throughput) || isnan(throughput))) break;

                bool transmission = bsdfSample.isLobe(LobeType::Transmission);
                float3 rayOrigin = sd.computeRayOrigin(!transmission);
                float segmentIoR = sd.IoR;
                hit = traceRay(rayOrigin, bsdfSample.wo, hitT);
                if (!hit.isValid()) break;
                sd = loadShadingData(hit, rayOrigin, bsdfSample.wo);
                pathLength += length(sd.posW - previous.posW) * segmentIoR;
                mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
            }
#endif
            if (any(isinf(result) || isnan(result))) result = 0.f;
            outColor += result;
        }
        outColor /= samplesPerPixel;
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    return outColor;
}

float3 evalDirectConnection(
    const ShadingData sd, const LightSample ls, const IMaterialInstance mi,
    float pathLength, inout SampleGenerator sg
)
{
    if (!ls.valid) return float3(0.f);
    float3 toLight = ls.posW() - sd.posW;
    float toLightDistance = length(toLight);
    if(toLightDistance < 1e-4){
        return float3(0.0);
    }
    float3 toLightDir = toLight / toLightDistance;
    float3 L = mi.eval(sd, toLightDir, sg) * ls.evalLi(sd.posW, sg);
    L *= pathLengthImportance(pathLength + toLightDistance + ls.laserT, tcurr);
    // Occlusion check for the final surface -> light segment. This also checks
    // y -> light when called by evalEllipsoidalConnection() for x -> y -> light.
    // Offset the light surface toward the shading point. A point light has no surface.
    float3 visibilityEndpoint = ls.posW();
#if IS_LIGHT_SOURCE_LASER
    float3 lightNormal = ls.getOrientedFaceNormal();
    visibilityEndpoint = computeRayOrigin(visibilityEndpoint, dot(lightNormal, -toLightDir) >= 0.f ? lightNormal : -lightNormal);
#endif
    float3 visibilityOrigin = sd.computeRayOrigin(dot(sd.getOrientedFaceNormal(), visibilityEndpoint - sd.posW) >= 0.f);
    // If the offsets cross, there is no forward visibility segment left to trace.
    if (dot(visibilityEndpoint - visibilityOrigin, toLightDir) <= 0.f) return float3(0.f);
    bool V = traceVisibilityRay(visibilityOrigin, visibilityEndpoint);
    return L * float(V);
}

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

struct EllipsoidalConnection
{
    float3 radiance; // Includes the sampling-density division, but neither throughput nor MIS weight.
    float ellipsePdf; // Solid-angle density at x for the direction x -> y.
    float directPdf;  // BSDF solid-angle density at x for the same direction.
};

bool canSampleEllipsoid(uint depth, bool hasNonDelta)
{
    // A connection inserts y after the current vertex x. Avoid unsigned subtraction.
    return hasNonDelta && depth + 1 < kMaxBounces;
}

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
    float3 direction = normalize(segment);
    float distanceSquared = max(dot(segment, segment), FLT_MIN);
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

float evalDeferredDirectWeight(DeferredConnection previous, ShadingData target, HitInfo hit, LightSample light)
{
    // A delta event has probability mass, not a continuous solid-angle density.
    if (previous.delta || !previous.ellipsoidEligible) return 1.f;
    float directPdf = previous.bsdfPdf;
    float ellipsePdf = 0.f;
    float connectionLength = length(target.posW - previous.posW) + length(target.posW - light.posW());
    Ellipsoid ellipse;
    if (buildEllipsoidFromFoci(previous.posW, light.posW(), connectionLength,
                              previous.normalW, light.getOrientedFaceNormal(), ellipse))
    {
        ellipsePdf = evalEllipsoidPdf(ellipse, hit, target, previous.pathLength + light.laserT);
    }
    return balanceWeight(directPdf, ellipsePdf);
}

// Sample and evaluate x -> y -> light. prefixLength ends at x (laserT is added here).
EllipsoidalConnection evalEllipsoidalConnection(
    ShadingData origin, LightSample light, IMaterialInstance material,
    float prefixLength, inout SampleGenerator sg)
{
    EllipsoidalConnection connection = {};
    if (!light.valid) return connection;
    float prefixWithLaser = prefixLength + light.laserT;
    float sampledLength, lengthPdf;
    samplePathLength(tcurr - prefixWithLaser, sampleNext1D(sg), sampledLength, lengthPdf);
    if (!(lengthPdf > 0.f)) return connection;

    Ellipsoid ellipse;
    if (!buildEllipsoidFromFoci(origin.posW, light.posW(), sampledLength,
                               origin.getOrientedFaceNormal(), light.getOrientedFaceNormal(), ellipse)) return connection;

    uint triangleIndex;
    float trianglePdf;
    if (!emissiveSampler.sampleTriangleEllipsoid(ellipse, sg, triangleIndex, trianglePdf)) return connection;
    if (triangleIndex >= gScene.triCollection.getTriangleCount()) return connection;
    EmissiveTriangle triangle = gScene.triCollection.getTriangle(triangleIndex);
    if (!supportsEllipsoidTriangle(ellipse, triangle)) return connection;

    SampleResultArea sample = sampleOnTriangleEllipsoid(
        ellipse, triangle.posW[0], triangle.posW[1], triangle.posW[2], sampleNext1D(sg), sampleNext1D(sg));
    if (!sample.ok) return connection;
    float ellipseAreaPdf = finitePositivePdf(lengthPdf * trianglePdf * sample.pdfA);
    if (ellipseAreaPdf == 0.f) return connection;

    // Visibility check 1: trace x -> sampled y. The closest hit must be the sampled
    // triangle; any intervening surface (or a miss) rejects the connection.
    // This hit also supplies y's shading data, so no separate shadow ray is needed here.
    float3 toTarget = sample.p - origin.posW;
    if (!(dot(toTarget, toTarget) > 0.f)) return connection;
    float3 direction = normalize(toTarget);
    float3 rayOrigin = origin.computeRayOrigin(dot(origin.getOrientedFaceNormal(), direction) >= 0.f);
    float hitDistance;
    HitInfo hit = traceRay(rayOrigin, normalize(sample.p - rayOrigin), hitDistance);
    if (getCollectionTriangleIndex(hit) != triangleIndex) return connection;
    ShadingData target = loadShadingData(hit, rayOrigin, direction);
    let targetMaterial = gScene.materials.getMaterialInstance(target, ExplicitLodTextureSampler(0.f));

    float segmentLength = length(target.posW - origin.posW);
    connection.ellipsePdf = areaPdfToSolidAngle(ellipseAreaPdf, origin.posW, target.posW, target.getOrientedFaceNormal());
    if (!(connection.ellipsePdf > 1e-7f)) return connection;
    // Match the cutoff that would stop the competing BSDF walk before reaching y.
    if (prefixLength + segmentLength * origin.IoR < getMaxpathLength(tcurr))
        connection.directPdf = material.evalPdf(origin, direction, kUseImportanceSampling);

    float3 firstScatter = material.eval(origin, direction, sg);
    // Visibility check 2: evalDirectConnection() traces y -> light and returns zero
    // when occluded. Together the two checks cover the full x -> y -> light connection.
    float3 directAtTarget = evalDirectConnection(target, light, targetMaterial, prefixLength + segmentLength, sg);
    connection.radiance = (firstScatter / connection.ellipsePdf) * directAtTarget;
    return connection;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
#if USE_SINGLE_CHANNEL
    color = float3(color.x, color.x, color.x);
#endif
    gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
}
