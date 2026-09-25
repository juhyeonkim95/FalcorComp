import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.Lights.EllipsoidalSampling;
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


HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
{
    Ray ray = Ray(origin, dir, 0.0, kRayTMax);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceRay(ray, hitT);
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

            // Direct illumination at the primary hit (camera -> primary -> light).
            if(kComputeDirect){
                // sample light
                LightSample ls = {};
                lls.generateLightSample(sg, ls);
                LightConnection connection = evaluateLightConnection(sd, mi, ls, sg);
                float gate = pathLengthImportance(pathLength + connection.distance + ls.laserT, tcurr);
                result += throughput * (connection.bsdfCosine * connection.incidentRadiance * gate);
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
                    LightConnection connection = evaluateLightConnection(sd, mi, ls, sg);
                    float gate = pathLengthImportance(pathLength + connection.distance + ls.laserT, tcurr);
                    result += throughput * (connection.bsdfCosine * connection.incidentRadiance * gate);
                }
            }
#elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION || LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
            ScatterRecord previous = {};
            for (uint depth = 0; depth < kMaxBounces && pathLength < maxPathLength; ++depth)
            {
                bool hasNonDelta = (mi.getLobeTypes(sd) & uint(LobeType::NonDelta)) != 0;
                bool useEllipsoid = canSampleEllipsoid(depth, hasNonDelta);
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
                useEllipsoid = useEllipsoid && mi.getProperties(sd).roughness > specularRoughnessThreshold;
#endif
                LightSample ls = {};
                lls.generateLightSample(sg, ls);

                // Ellipsoidal technique at x: completes x -> y -> light immediately.
                if (useEllipsoid && ls.valid)
                {
                    EllipsoidalEstimate estimate = estimateEllipsoidalPath(sd, ls, mi, pathLength, sg);
#if LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS
                    float weight = balanceWeight(estimate.ellipsePdf, estimate.bsdfPdf);
#else
                    float weight = 1.f;
#endif
                    result += throughput * weight * estimate.radiance;
                }

                // BSDF technique at y: the walk sampled x -> y, now connect y -> light.
                if (depth > 0 && hasNonDelta && ls.valid)
                {
                    float weight = evalBsdfTechniqueWeight(previous, sd, hit, ls, tcurr, emissiveSampler,
                        LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_DIRECT_MIS);
                    if (weight > 0.f)
                    {
                        LightConnection connection = evaluateLightConnection(sd, mi, ls, sg);
                        float gate = pathLengthImportance(pathLength + connection.distance + ls.laserT, tcurr);
                        result += throughput * weight * (connection.bsdfCosine * connection.incidentRadiance * gate);
                    }
                }

                if (depth + 1 >= kMaxBounces) break;
                previous.posW = sd.posW;
                previous.normalW = sd.getOrientedFaceNormal();
                previous.pathLength = pathLength;
                // Eligibility does not depend on whether the independent light/ellipse draw succeeded.
                previous.ellipsoidEligible = useEllipsoid;
                if (!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)) break;
                previous.isDelta = bsdfSample.isLobe(LobeType::Delta);
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

bool canSampleEllipsoid(uint depth, bool hasNonDelta)
{
    // A connection inserts y after the current vertex x. Avoid unsigned subtraction.
    return hasNonDelta && depth + 1 < kMaxBounces;
}

// Ellipsoidal-technique estimate of x -> y -> light, before throughput and MIS weight.
struct EllipsoidalEstimate
{
    float3 radiance;  // f(x) * cosine / ellipsePdf * f(y) * cosine * Li(y) * gate.
    float ellipsePdf; // Solid-angle density at x of the sampled direction x -> y.
    float bsdfPdf;    // BSDF-technique density at x for the same direction (MIS).
};

// Sample y on the ellipsoid and connect it to the light. prefixLength ends at x.
EllipsoidalEstimate estimateEllipsoidalPath(
    ShadingData x, LightSample light, IMaterialInstance material,
    float prefixLength, inout SampleGenerator sg)
{
    EllipsoidalEstimate estimate = {};
    if (!light.valid) return estimate;
    EllipsoidalSample ellipsoidal;
    if (!sampleEllipsoid(x, prefixLength, light, tcurr, emissiveSampler, sg, ellipsoidal)) return estimate;
    ShadingData y = ellipsoidal.surface;
    let yMaterial = gScene.materials.getMaterialInstance(y, ExplicitLodTextureSampler(0.f));
    estimate.ellipsePdf = ellipsoidal.pdf;
    if (!(estimate.ellipsePdf > 1e-7f)) return estimate;
    // Match the cutoff that would stop the competing BSDF walk before reaching y.
    if (prefixLength + ellipsoidal.distance * x.IoR < getMaxpathLength(tcurr))
        estimate.bsdfPdf = material.evalPdf(x, ellipsoidal.direction, kUseImportanceSampling);

    float3 firstScatter = material.eval(x, ellipsoidal.direction, sg);
    // sampleEllipsoid() traced x -> y; this connection traces y -> light and is
    // zero when occluded. Together the two checks cover the full x -> y -> light path.
    LightConnection connection = evaluateLightConnection(y, yMaterial, light, sg);
    float gate = pathLengthImportance(prefixLength + ellipsoidal.distance * x.IoR + connection.distance + light.laserT, tcurr);
    estimate.radiance = (firstScatter / estimate.ellipsePdf) *
        (connection.bsdfCosine * connection.incidentRadiance * gate);
    return estimate;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
#if USE_SINGLE_CHANNEL
    color = float3(selectChannel(color));
#endif
    gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
}
