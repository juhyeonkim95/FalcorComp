/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
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
// Steady-state path tracing using a V-buffer and inline ray queries.
// Analytic lights use explicit sampling. Emission and environment lighting use
// BSDF sampling only, keeping the estimator simple and avoiding double counting.
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;
    uint gSamplesPerPixel;
    uint gPRNGDimension;
}
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseAlphaTest = USE_ALPHA_TEST;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

bool traceShadowRay(const ShadingData surface, const AnalyticLightSample light, uint lightType)
{
    float3 origin = surface.computeRayOrigin(dot(surface.getOrientedFaceNormal(), light.dir) >= 0.f);
    SceneRayQuery<kUseAlphaTest> query;
    // Infinite lights have no finite endpoint (their posW is a dummy value).
    if (lightType == LightType::Directional || lightType == LightType::Distant)
        return query.traceVisibilityRay(Ray(origin, light.dir, 0.f, light.distance));

    float3 endpoint = light.posW;
    if (lightType == LightType::Rect || lightType == LightType::Sphere || lightType == LightType::Disc)
        endpoint = computeRayOrigin(endpoint, dot(light.normalW, -light.dir) >= 0.f ? light.normalW : -light.normalW);
    float3 segment = endpoint - origin;
    float distance = length(segment);
    if (!(distance > 0.f) || !isfinite(distance) || !(dot(segment, light.dir) > 0.f)) return false;
    return query.traceVisibilityRay(Ray(origin, segment / distance, 0.f, distance));
}

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

float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

    // Sample local light source.
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
        return float3(0.f);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
    if ((NdotL <= kMinCosTheta && !hasTransmission) || (NdotL >= -kMinCosTheta && !hasReflection))
        return float3(0.f);

    // Only the visibility ray uses offset positions; shading uses the original light sample.
    bool V = traceShadowRay(sd, ls, gScene.getLight(lightIndex).type);
    if (!V)
        return float3(0.f);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

float3 tracePath(uint2 pixel, uint sampleIndex)
{
    float3 rayOrigin = gScene.camera.getPosition();
    float3 rayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (!hit.isValid())
        return kUseEnvBackground ? gScene.envMap.eval(rayDir) : float3(0.f);

    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * gSamplesPerPixel + sampleIndex);
    for (uint dimension = 0; dimension < gPRNGDimension; ++dimension)
        sampleNext1D(sg);

    float3 radiance = float3(0.f);
    float3 throughput = float3(1.f);
    ShadingData sd = loadShadingData(hit, rayOrigin, rayDir);
    let primaryMaterial = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    if (kComputeDirect)
        radiance += primaryMaterial.getProperties(sd).emission;

    // At depth zero, the outgoing segment samples direct mesh/environment light.
    // Each additional depth adds one indirect scattering vertex.
    for (uint depth = 0; ; ++depth)
    {
        let mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        if (kUseAnalyticLights && (kComputeDirect || depth > 0))
            radiance += throughput * evalDirectAnalytic(sd, mi, sg);

        BSDFSample sample;
        if (!mi.sample(sd, sg, sample, kUseImportanceSampling)) break;
        throughput *= sample.weight;
        if (!any(throughput > 0.f)) break;

        if (hit.getType() == HitType::Curve)
            rayOrigin = sd.posW - sd.curveRadius * sd.frame.N;
        else
            rayOrigin = sd.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
        rayDir = sample.wo;
        float hitT;
        SceneRayQuery<kUseAlphaTest> query;
        hit = query.traceRay(Ray(rayOrigin, rayDir, 0.f, FLT_MAX), hitT);
        if (!hit.isValid())
        {
            if (kUseEnvLight && (kComputeDirect || depth > 0))
                radiance += throughput * gScene.envMap.eval(rayDir);
            break;
        }

        sd = loadShadingData(hit, rayOrigin, rayDir);
        if (kUseEmissiveLights && (kComputeDirect || depth > 0))
        {
            let emitter = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
            radiance += throughput * emitter.getProperties(sd).emission;
        }
        if (depth >= kMaxBounces) break;
    }
    return radiance;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;

    float3 radiance = float3(0.f);
    for (uint sampleIndex = 0; sampleIndex < gSamplesPerPixel; ++sampleIndex)
        radiance += tracePath(pixel, sampleIndex);
    gOutputColor[pixel] = float4(radiance / gSamplesPerPixel, 1.f);
}
