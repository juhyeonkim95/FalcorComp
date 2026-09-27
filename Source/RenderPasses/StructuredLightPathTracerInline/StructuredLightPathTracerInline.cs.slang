import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Projector.ProjectorLight;
import RenderPasses.Shared.Shaders.Projector.ProjectorPatterns;
import RenderPasses.Shared.Shaders.Antithetic.AntitheticMIS;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;

// SAMPLING_METHOD: how the vertex lit by the projector is reached from the camera path.
#define SAMPLING_BSDF 0       // BSDF sampling.
#define SAMPLING_ANTITHETIC 1 // BSDF sampling, each sample paired with its antithetic partner in projector space.
#define SAMPLING_PROJECTOR 2  // Sampled from the projector (stratified along the pattern axis) and connected.

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gSamplesPerPixel;
    uint gProjectorSampleCount; // SAMPLING_PROJECTOR: projector samples per vertex.
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const bool kUseAlphaTest = USE_ALPHA_TEST;

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kEpsilon = 1e-6f;


bool traceVisibilityRay(const float3 origin, const float3 dir, const float distance)
{
    Ray visibilityRay = Ray(origin, dir, 0.0, distance - 1e-3f);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}


/// Whether `surface` sees the projector along `connection` (the projector lights it).
bool isLit(ShadingData surface, ProjectorConnection connection)
{
    return traceVisibilityRay(rayOriginToward(surface, connection.direction), connection.direction, connection.distance);
}

/// Connection of `surface` to the projector: BSDF * cosine * emitted radiance / distance^2, zero outside the
/// frustum or when occluded.
float3 evaluateProjectorConnection(ShadingData surface, IMaterialInstance material, ProjectorLight projector,
    inout SampleGenerator sg)
{
    ProjectorConnection connection;
    if (!projector.connect(surface.posW, connection) || !isLit(surface, connection)) return float3(0.f);
    return material.eval(surface, connection.direction, sg) * connection.radiance /
        (connection.distance * connection.distance);
}

/// |dw / duv|, up to a constant: the solid angle at `previous` of the surface point hit by the projector ray
/// through uv, per unit uv.
float solidAngleFromPreviousPerUV(float3 previous, ShadingData surface)
{
    float3 toSurface = surface.posW - previous;
    float3 fromProjector = surface.posW - gProjectorPosition;
    float distanceSquared = dot(toSurface, toSurface);
    float projectorDistanceSquared = dot(fromProjector, fromProjector);
    if (!(distanceSquared > kEpsilon) || !(projectorDistanceSquared > kEpsilon)) return 0.f;
    float3 normal = surface.getOrientedFaceNormal();
    float cosToPrevious = abs(dot(normal, toSurface)) / sqrt(distanceSquared);
    float cosToProjector = abs(dot(normal, fromProjector)) / sqrt(projectorDistanceSquared);
    float cosProjector = abs(dot(gProjectorForward, fromProjector)) / sqrt(projectorDistanceSquared);
    if (!(cosToPrevious > kEpsilon) || !(cosToProjector > kEpsilon)) return 0.f;
    return cosToPrevious / distanceSquared * projectorDistanceSquared / cosToProjector *
        cosProjector * cosProjector * cosProjector;
}

/** Estimate of the BSDF-sampled segment previous -> surface and its antithetic partner, each connected to the
    projector (AntitheticMIS). The partner is where the projector ray through the pattern's antithetic uv lands,
    so the pattern has the opposite sign there. The map is defined on points the projector lights that `previous`
    sees directly, which holds for both points of a pair; elsewhere the primal estimate is returned alone.
    @param[in] primalEstimate throughput * f / p of the primal path, connected to the projector.
*/
float3 estimateWithAntithetic(ShadingData previous, IMaterialInstance previousMaterial, ShadingData surface,
    BSDFSample bsdfSample, ProjectorLight projector, float3 throughput, float3 primalEstimate, inout SampleGenerator sg)
{
    float mapChoice = sampleNext1D(sg);
    if (bsdfSample.isLobe(LobeType::Delta) || !(bsdfSample.pdf > 0.f)) return primalEstimate;

    ProjectorConnection primal;
    if (!projector.connect(surface.posW, primal) || !isLit(surface, primal)) return primalEstimate;

    float3 projectorDir;
    if (!projector.uvToDirection(projector.pattern.antitheticCoord(primal.uv, mapChoice), projectorDir))
        return primalEstimate;
    float hitT;
    HitInfo hit = traceRay(projector.position(), projectorDir, hitT);
    if (!hit.isValid()) return primalEstimate;
    float3 toAntithetic = projector.position() + hitT * projectorDir - previous.posW;
    float antitheticDistance = length(toAntithetic);
    if (!(antitheticDistance > kEpsilon)) return primalEstimate;
    float3 antitheticDir = toAntithetic / antitheticDistance;
    if (!traceVisibilityRay(rayOriginToward(previous, antitheticDir), antitheticDir, antitheticDistance))
        return primalEstimate;

    ShadingData antithetic = loadShadingData(hit, previous.posW, antitheticDir);
    let antitheticMaterial = gScene.materials.getMaterialInstance(antithetic, ExplicitLodTextureSampler(0.f));

    // |dw_a / dw| = (dw_a / duv_a) / (dw / duv) * |duv_a / duv|.
    float primalDensity = solidAngleFromPreviousPerUV(previous.posW, surface);
    float antitheticDensity = solidAngleFromPreviousPerUV(previous.posW, antithetic);
    if (!(primalDensity > 0.f) || !(antitheticDensity > 0.f)) return primalEstimate;
    float jacobian = antitheticDensity / primalDensity * abs(projector.pattern.antitheticJacobian(primal.uv));
    if (!(jacobian > 0.f) || !isfinite(jacobian)) return primalEstimate;

    float antitheticBsdfPdf = previousMaterial.evalPdf(previous, antitheticDir, kUseImportanceSampling);
    float3 antitheticValue = throughput * previousMaterial.eval(previous, antitheticDir, sg) *
        evaluateProjectorConnection(antithetic, antitheticMaterial, projector, sg);
    return combineAntithetic(primalEstimate, bsdfSample.pdf, antitheticValue, antitheticBsdfPdf, jacobian);
}

/** Paths ... -> x -> y -> projector with y sampled from the projector: gProjectorSampleCount projector rays,
    stratified along the pattern axis, each connected to x. Returns the estimate before the path throughput.
*/
float3 estimateProjectorSampledPaths(ShadingData x, IMaterialInstance material, ProjectorLight projector,
    inout SampleGenerator sg)
{
    float3 estimate = float3(0.f);
    uint count = gProjectorSampleCount;
    float across = sampleNext1D(sg);
    for (uint j = 0; j < count; j++)
    {
        float along = (float(j) + sampleNext1D(sg)) / float(count);
        float2 uv = gPatternAxis == 0 ? float2(along, across) : float2(across, along);
        float3 projectorDir;
        if (!projector.uvToDirection(uv, projectorDir)) continue;
        float hitT;
        HitInfo hit = traceRay(projector.position(), projectorDir, hitT);
        if (!hit.isValid()) continue;
        ShadingData y = loadShadingData(hit, projector.position(), projectorDir);
        let yMaterial = gScene.materials.getMaterialInstance(y, ExplicitLodTextureSampler(0.f));

        float3 toY = y.posW - x.posW;
        float distanceSquared = dot(toY, toY);
        if (!(distanceSquared > 0.f)) continue;
        float3 direction = toY / sqrt(distanceSquared); // x -> y
        // One-sided connection: y must face x and x must face y.
        if (!(dot(direction, x.getOrientedFaceNormal()) > kEpsilon) || !(dot(-direction, y.getOrientedFaceNormal()) > kEpsilon))
            continue;
        if (!traceVisibilityRay(x.computeRayOrigin(), direction, sqrt(distanceSquared))) continue;

        // Area measure at y: f(x) cos_x * f(y) cos_y / |x - y|^2 * L_e cos_o / |o - y|^2 over
        // pdf_dir cos_o / |o - y|^2; y's shading data sees the projector, so f(y) cos_y is yMaterial.eval(-direction).
        float3 radiance = projector.emittedRadiance(uv, projectorDir);
        estimate += material.eval(x, direction, sg) * yMaterial.eval(y, -direction, sg) * radiance /
            (projector.directionPdf(projectorDir) * distanceSquared);
    }
    return estimate / float(count);
}

// Trace camera paths and connect them to the projector.
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gViewW);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);

        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        ProjectorLight projector = {};

        for (uint i = 0; i < gSamplesPerPixel; i++)
        {
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);

            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;

            // Direct illumination at the primary hit (camera -> primary -> projector). The primary hit comes from
            // the V-buffer, not from a BSDF sample, so it has no antithetic partner.
            if (kComputeDirect)
                result += throughput * evaluateProjectorConnection(sd, mi, projector, sg);

            for (uint depth = 1; depth < kMaxBounces; depth++)
            {
#if SAMPLING_METHOD == SAMPLING_PROJECTOR
                result += throughput * estimateProjectorSampledPaths(sd, mi, projector, sg);
                if (depth + 1 >= kMaxBounces) break;
#endif
                BSDFSample bsdfSample = {};
                if (!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)) break;

                ShadingData previous = sd;
                IMaterialInstance previousMaterial = mi;
                bool transmission = bsdfSample.isLobe(LobeType::Transmission);
                float3 rayOrigin = sd.computeRayOrigin(!transmission);
                float hitT;
                HitInfo hit = traceRay(rayOrigin, bsdfSample.wo, hitT);
                if (!hit.isValid()) break;

                sd = loadShadingData(hit, rayOrigin, bsdfSample.wo);
                mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

#if SAMPLING_METHOD != SAMPLING_PROJECTOR
                float3 primalEstimate = throughput * bsdfSample.weight * evaluateProjectorConnection(sd, mi, projector, sg);
#if SAMPLING_METHOD == SAMPLING_ANTITHETIC
                result += estimateWithAntithetic(previous, previousMaterial, sd, bsdfSample, projector, throughput,
                    primalEstimate, sg);
#else
                result += primalEstimate;
#endif
#endif
                throughput *= bsdfSample.weight;
                if (!any(throughput > 0.f) || any(throughput < 0.f)) break;
            }
            if (any(isinf(result) || isnan(result))) result = 0.f;
            outColor += result;
        }
        outColor /= gSamplesPerPixel;
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    return outColor;
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
    gOutputColor[pixel] = float4(color, 1.f);
}
