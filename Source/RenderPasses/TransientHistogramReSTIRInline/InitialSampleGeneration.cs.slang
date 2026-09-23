#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Scene.RaytracingInline;
import RenderPasses.Shared.ReSTIR.Reservoirs;

import RenderPasses.Shared.Utils.LoadShadingData;
import RenderPasses.Shared.Lights.LaserLightSampler;
import RenderPasses.Shared.Lights.LightConnection;
import RenderPasses.Shared.ReSTIR.PathReconstruction;
import RenderPasses.Shared.ReSTIR.InitialCandidates;


cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gRandomSeed;    // Frame count since scene was loaded.
    
    uint gPRNGDimension; // First available PRNG dimension.
    uint samplesPerPixel;
    uint2 gLaserHitVBufferRes;
    float specularRoughnessThreshold;
    float gRoughTimeGateSampleRatio;
}

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
}


// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional


// Laser V Buffer (1 pixel)
Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW;

// Laser Hit V Buffer (256 x 256)
Texture2D<PackedHitInfo> gLaserHitVBuffer;
Texture2D<float4> gLaserHitViewW;
Texture2D<float> gLaserHitDepth;

// Reservoir Struct
RWStructuredBuffer<Reservoir> currReservoirs;

// Outputs
RWTexture2D<float4> gOutputColor;

#if USE_SINGLE_CHANNEL
RWTexture3D<float> gTransientHistogram;
#else
RWTexture3D<float4> gTransientHistogram;
#endif


// TimeGateMode::BOX; macros in imported Slang modules are not exported.
static const uint kTimeGateBox = 1;

float3 getPrimaryRayDir(uint2 pixel, uint2 frameDim)
{
#if is_valid_gViewW
    return -gViewW[pixel].xyz;
#else
    return gScene.camera.computeRayPinhole(pixel, frameDim).dir;
#endif
}

// The same completed path is a candidate for every gate it overlaps.
// Box bins are disjoint, so that common case updates only one reservoir.
void submitHistogramCandidate(uint pixelIndex, ReconnectionState rc, ShadingData surface,
    IMaterialInstance material, LightSample light, LightConnection connection,
    float totalLength, float3 throughput, uint lightSeed, inout SampleGenerator rng)
{
    uint firstBin = 0;
    uint endBin = tbin;
    if (time_gate_mode == kTimeGateBox)
    {
        if (!(totalLength >= tmin && totalLength < tmax)) return;
        firstBin = min(uint((totalLength - tmin) / tunit), tbin - 1);
        endBin = firstBin + 1;
    }
    for (uint bin = firstBin; bin < endBin; ++bin)
    {
        float center = tmin + (float(bin) + 0.5f) * tunit;
        // Half-open box bins assign boundary samples exactly once.
        float gate = time_gate_mode == kTimeGateBox ? 1.f : pathLengthImportance(totalLength, center);
        if (!(gate > 0.f)) continue;
        uint index = pixelIndex * tbin + bin;
        Reservoir reservoir = currReservoirs[index];
        submitCandidate(reservoir, rc, surface, material, light, connection, totalLength, gate,
            throughput, 1.f, samplesPerPixel, lightSeed, true, rng);
        currReservoirs[index] = reservoir;
    }
}

float3 tracePath(uint2 pixel, uint2 frameDim)
{
    uint pixelIndex = pixel.y * frameDim.x + pixel.x;
    for (uint bin = 0; bin < tbin; ++bin)
    {
        currReservoirs[pixelIndex * tbin + bin] = Reservoir();
        gTransientHistogram[uint3(pixel, bin)] = 0.f;
    }
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return 0.f;

    float3 cameraPosition = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraPosition, getPrimaryRayDir(pixel, frameDim));
    let primaryMaterial = gScene.materials.getMaterialInstance(primary, ExplicitLodTextureSampler(0.f));
    float primaryLength = length(primary.posW - cameraPosition);
    float maxPathLength = getMaxpathLength(tmin + (float(tbin) - 0.5f) * tunit);
    LaserLightSampler lightSampler = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);
    // Prefix replay must not consume light or reservoir RNG draws.
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

        // Match the histogram PT convention: primary = depth zero.
        for (uint depth = 0; depth < max(1u, uint(MAX_BOUNCES)) &&
            pathLength < maxPathLength && any(throughput > 0.f); ++depth)
        {
            if (depth > 0 || COMPUTE_DIRECT)
            {
                LightSample light = {};
                uint lightSeed = lightRng.getCurrentSeed();
                lightSampler.generateLightSample(lightRng, light);
                LightConnection connection = evaluateLightConnection(surface, material, light, rng);
                float totalLength = pathLength + connection.distance + light.laserT;
                submitHistogramCandidate(pixelIndex, rc, surface, material, light, connection, totalLength,
                    throughput, lightSeed, rng);
            }
            if (rc.bounce > 0) ++rc.postBounce;
            if (depth + 1 >= MAX_BOUNCES) break;

            bool previousDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            uint sampleSeed = bsdfRng.getCurrentSeed();
            BSDFSample sample = {};
            if (!material.sample(surface, bsdfRng, sample, USE_IMPORTANCE_SAMPLING)) break;
            throughput *= sample.weight;
            float suffixDirectionWeight = 0.f;
            if (rc.postBounce == 2 && sample.pdf > 0.f)
                suffixDirectionWeight = shadingCosine(surface, material, sample.wo) / sample.pdf;

            float3 previousPosition = surface.posW;
            float segmentIoR = surface.IoR;
            float3 origin = surface.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
            SceneRayQuery<USE_ALPHA_TEST> query;
            float hitT;
            HitInfo hit = query.traceRay(Ray(origin, sample.wo, 0.f, FLT_MAX), hitT);
            if (!hit.isValid()) break;
            surface = loadShadingData(hit, origin, sample.wo);
            material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            float segmentLength = length(surface.posW - previousPosition);
            // Match time-gated generation and shared prefix replay.
            pathLength += segmentLength * segmentIoR;
            bool currentDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            rc.recordHit(hit, surface, sample, depth + 1,
                previousDiffuse && currentDiffuse && segmentLength > 0.f,
                segmentLength, segmentIoR, suffixDirectionWeight, sampleSeed);
        }
    }

    float3 integratedRadiance = 0.f;
    for (uint bin = 0; bin < tbin; ++bin)
    {
        uint index = pixelIndex * tbin + bin;
        Reservoir reservoir = currReservoirs[index];
        float target = getReservoirWeight(reservoir.f);
        reservoir.W = target > 0.f ? reservoir.wSum / target : 0.f;
        // Each bin had samplesPerPixel path trials, including paths contributing zero.
        reservoir.M = samplesPerPixel;
        currReservoirs[index] = reservoir;
        float3 radiance = reservoir.W * reservoir.f;
        integratedRadiance += radiance;
#if USE_SINGLE_CHANNEL
        gTransientHistogram[uint3(pixel, bin)] = radiance.x / tunit;
#else
        gTransientHistogram[uint3(pixel, bin)] = float4(radiance / tunit, 1.f);
#endif
    }
    return integratedRadiance;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] = float4(tracePath(pixel, gFrameDim), 1.f);
}
