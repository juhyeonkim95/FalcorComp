import RenderPasses.Shared.Utils.LoadShadingData;
import RenderPasses.Shared.Lights.LaserLightSampler;
import RenderPasses.Shared.Lights.LightConnection;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Scene.RaytracingInline;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // First available PRNG dimension.

    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;

    uint samplesPerPixel;
    float initialWindowRatio;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

#if USE_SINGLE_CHANNEL
RWTexture3D<float> gTransientHistogram;
#else
RWTexture3D<float4> gTransientHistogram;
#endif

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseAlphaTest = USE_ALPHA_TEST;

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


// Histogram values are radiance density per unit path length, summed across frames.
// RGB alpha is auxiliary weight; single-channel storage deliberately uses red, not luminance.
void addHistogramBin(uint2 pixel, uint bin, float3 radiance, float weight = 1.f)
{
#if USE_SINGLE_CHANNEL
    gTransientHistogram[uint3(pixel, bin)] += radiance.x * weight;
#else
    gTransientHistogram[uint3(pixel, bin)] += float4(radiance, 1.f) * weight;
#endif
}

void accumulateToHistogram(uint2 pixel, float pathLength, float3 radiance, float window)
{
    if (!isfinite(pathLength)) return;
#if USE_KERNEL_DENSITY_ESTIMATION
    radiance /= window * samplesPerPixel;
    for (uint bin = 0; bin < tbin; ++bin)
    {
        float center = tmin + (bin + 0.5f) * tunit;
        float weight = pathLengthImportanceGivenWindow(pathLength, center, window);
        if (weight > 0.f) addHistogramBin(pixel, bin, radiance * weight);
    }
#else
    // Half-open range prevents tmax from being incorrectly added to the final bin.
    if (pathLength < tmin || pathLength >= tmax) return;
    float coordinate = (pathLength - tmin) / tunit;
    uint bin = min(uint(coordinate), tbin - 1);
    radiance /= tunit * samplesPerPixel;
#if HISTOGRAM_FILTER == HISTOGRAM_FILTER_BOX
    addHistogramBin(pixel, bin, radiance);
#elif HISTOGRAM_FILTER == HISTOGRAM_FILTER_TENT
    // Retain the existing interpolation and final-bin clamping convention.
    float residual = frac(coordinate);
    addHistogramBin(pixel, bin, radiance, 1.f - residual);
    addHistogramBin(pixel, min(bin + 1, tbin - 1), radiance, residual);
#endif
#endif
}

// Each pixel owns all of its bins, so histogram updates require no atomics.
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return float3(0.f);
    float3 cameraOrigin = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraOrigin, getPrimaryRayDir(pixel, frameDim, gScene.camera));
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 151);
    LaserLightSampler lightSampler = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);
    float3 radiance = 0.f;
    // Preserve the existing per-frame progressive KDE bandwidth schedule.
    float window = (tmax - tmin) * initialWindowRatio;
#if USE_KERNEL_DENSITY_ESTIMATION
    // Ad hoc extension: paths beyond the histogram range can contribute through KDE support.
    const float maxPathLength = 1.5f * tmax;
#else
    const float maxPathLength = tmax;
#endif
    for (uint sample = 0; sample < samplesPerPixel; ++sample)
    {
        ShadingData surface = primary;
        float pathLength = length(primary.posW - cameraOrigin);
        float3 throughput = 1.f;
        // Preserve the legacy bounce convention: the primary vertex is depth zero,
        // and maxBounces=3 permits two subsequent scattering vertices.
        for (uint depth = 0; depth < max(1u, kMaxBounces) && pathLength < maxPathLength && any(throughput > 0.f); ++depth)
        {
            IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            if (depth > 0 || kComputeDirect)
            {
                LightSample light = {};
                lightSampler.generateLightSample(sg, light);
                if (light.valid)
                {
                    LightConnection connection = evaluateLightConnection(surface, material, light, sg);
                    float totalLength = pathLength + connection.distance + light.laserT;
                    float3 contribution = throughput * connection.bsdfCosine * connection.incidentRadiance;
                    radiance += contribution;
                    accumulateToHistogram(pixel, totalLength, contribution, window);
                }
            }
            if (depth + 1 >= kMaxBounces) break;
            BSDFSample bsdfSample;
            if (!material.sample(surface, sg, bsdfSample, kUseImportanceSampling)) break;
            throughput *= bsdfSample.weight;
            float3 origin = surface.computeRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
            float hitT;
            HitInfo hit = traceRay(origin, bsdfSample.wo, hitT);
            if (!hit.isValid()) break;
            ShadingData next = loadShadingData(hit, origin, bsdfSample.wo);
            pathLength += length(next.posW - surface.posW) * surface.IoR;
            surface = next;
        }
        window *= (sample + 0.8f) / (sample + 1.f);
    }
    return radiance / samplesPerPixel;
}

#if LIGHT_SAMPLING_METHOD == TRIANGLE_APPROX
float3 integrateLinearGate(float ls[3], float3 fs[3], float l, float l_width)
{
    float gateMin = l - 0.5 * l_width;
    float gateMax = l + 0.5 * l_width;
    float fmin = ls[0];
    float fmax = ls[2];

    // A constant path length deposits the triangle's average value in its bin.
    if (!(fmax > fmin))
        return (fmin >= gateMin && fmin < gateMax) ? (fs[0] + fs[1] + fs[2]) / 3.f : float3(0.f);

    // If gate is completely outside the defined range, return zero.
    if (gateMax <= fmin || gateMin >= fmax)
        return 0.0;

    float3 total = 0.0;

    // Integrate segment by segment
    for (int i = 0; i < 2; i++)
    {
        float x0 = ls[i];
        float x1 = ls[i + 1];
        float3 y0 = fs[i];
        float3 y1 = fs[i + 1];

        // Segment overlap with gate
        float segMin = max(x0, gateMin);
        float segMax = min(x1, gateMax);
        if (segMax <= segMin) continue;

        // Linear interpolation at overlap edges
        float3 f0 = y0 + (y1 - y0) * (segMin - x0) / (x1 - x0);
        float3 f1 = y0 + (y1 - y0) * (segMax - x0) / (x1 - x0);

        // Integral of a linear segment = (width * average height)
        total += 0.5 * (f0 + f1) * (segMax - segMin);
    }

    return total / (fmax - fmin);
}

void sortTriangleSamples(inout float lengths[3], inout float3 values[3])
{
    for (uint i = 0; i < 2; ++i)
    {
        for (uint j = i + 1; j < 3; ++j)
        {
            if (lengths[i] <= lengths[j]) continue;
            float length = lengths[i]; lengths[i] = lengths[j]; lengths[j] = length;
            float3 value = values[i]; values[i] = values[j]; values[j] = value;
        }
    }
}

// Deterministic single-intermediate-triangle approximation. It uses center visibility,
// vertex integrands and linear path-length interpolation, not unbiased path sampling.
// samplesPerPixel and maxBounces apply only to the direct path walk.
float3 tracePathTriangleApprox(const uint2 pixel, const uint2 frameDim)
{
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return float3(0.f);
    float3 cameraOrigin = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraOrigin, getPrimaryRayDir(pixel, frameDim, gScene.camera));
    IMaterialInstance primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float primaryLength = length(primary.posW - cameraOrigin);
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 151);

    // Preserve the approximation's collimated-laser assumption.
    LaserLightSampler sampler = LaserLightSampler(laserOrigin, laserDirection, 1.f, laserPower);
    LightSample light = {};
    sampler.generateLightSample(sg, light);
    if (!light.valid) return float3(0.f);

    const float epsilon = 1e-4f;
    const float2 barycentrics[3] = {float2(epsilon, epsilon), float2(1.f - epsilon, epsilon), float2(epsilon, 1.f - epsilon)};
    float3 radiance = 0.f;
    uint triangleCount = gScene.triCollection.getActiveTriangleCount();
    for (uint i = 0; i < triangleCount; ++i)
    {
        EmissiveTriangle triangle = gScene.triCollection.getTriangle(gScene.triCollection.activeTriangles[i]);
        float3 center = (triangle.posW[0] + triangle.posW[1] + triangle.posW[2]) / 3.f;
        float3 toCenter = center - primary.posW;
        if (!(dot(toCenter, toCenter) > 0.f) || !(triangle.area > 0.f)) continue;
        float3 direction = normalize(toCenter);
        if (abs(dot(direction, primary.getOrientedFaceNormal())) < 1e-5f) continue;
        float hitT;
        float3 origin = primary.computeRayOrigin(dot(primary.getOrientedFaceNormal(), direction) >= 0.f);
        HitInfo centerHit = traceRay(origin, direction, hitT);
        if (!centerHit.isValid() || centerHit.getType() != HitType::Triangle) continue;
        ShadingData centerSurface = loadShadingData(centerHit, origin, direction);
        if (length(centerSurface.posW - center) >= 1e-2f ||
            abs(dot(centerSurface.faceN, triangle.normal)) <= 0.99f) continue;
        if (!checkLightVisibility(centerSurface, light)) continue;

        float lengths[3];
        float3 values[3];
        for (uint vertex = 0; vertex < 3; ++vertex)
        {
            float2 bary = barycentrics[vertex];
            TriangleHit hit = centerHit.getTriangleHit();
            hit.barycentrics = bary;
            float3 position = triangle.posW[0] * (1.f - bary.x - bary.y) + triangle.posW[1] * bary.x + triangle.posW[2] * bary.y;
            float3 toVertex = position - primary.posW;
            if (!(dot(toVertex, toVertex) > 0.f))
            {
                lengths[vertex] = primaryLength + length(light.posW() - position) + light.laserT;
                values[vertex] = 0.f;
                continue;
            }
            ShadingData surface = loadShadingData(HitInfo(hit), origin, normalize(toVertex));
            IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            float3 toLight = light.posW() - surface.posW;
            float distance = length(surface.posW - primary.posW);
            lengths[vertex] = primaryLength + distance + length(toLight) + light.laserT;
            values[vertex] = 0.f;
            if (!(dot(toLight, toLight) > 0.f)) continue;
            float3 firstScatter = primaryMaterial.eval(primary, normalize(surface.posW - primary.posW), sg);
            float3 secondScatter = material.eval(surface, normalize(toLight), sg);
            // Keep the existing center-direction approximation to the area Jacobian.
            float cosine = abs(dot(surface.getOrientedFaceNormal(), -direction));
            values[vertex] = firstScatter * secondScatter * light.evalLi(surface.posW, sg) *
                             cosine * triangle.area / max(distance * distance, kMinLightDistSqr);
        }
        sortTriangleSamples(lengths, values);
        for (uint bin = 0; bin < tbin; ++bin)
        {
            float3 density = integrateLinearGate(lengths, values, tmin + (bin + 0.5f) * tunit, tunit) / tunit;
            addHistogramBin(pixel, bin, density);
            radiance += density * tunit;
        }
    }
    return radiance;
}

#endif // TRIANGLE_APPROX

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
    float3 color = tracePath(pixel, gFrameDim);
#elif LIGHT_SAMPLING_METHOD == TRIANGLE_APPROX
    float3 color = tracePathTriangleApprox(pixel, gFrameDim);
#endif
    gOutputColor[pixel] = float4(color, 1.f);
}
