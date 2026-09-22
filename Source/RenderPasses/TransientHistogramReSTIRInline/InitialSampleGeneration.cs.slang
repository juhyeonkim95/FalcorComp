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
import RenderPasses.Shared.ReSTIR.PathReconstruction;


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
    float areaPdf;              // p_A(a->x), then p_A(a->x) * p_A(x->y).
    float3 suffixThroughput;    // cosine_y/pdf_y, then sampled weights at z and beyond.
    float suffixLength;        // y->...->current surface; excludes current->light.

    [mutating]
    void recordHit(HitInfo hit, ShadingData surface, BSDFSample sample, uint depth,
        bool eligible, float segmentLength, float suffixDirectionWeight)
    {
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
            suffixThroughput *= suffixDirectionWeight;
            suffixLength += segmentLength * surface.IoR;
        }
        else
        {
            suffixThroughput *= sample.weight;
            suffixLength += segmentLength * surface.IoR;
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
    if (!(connection.distance > 0.f) || !isfinite(connection.distance)) return connection;
    connection.direction = segment / connection.distance;
    bool visible = checkLightVisibility(surface, light);
    connection.bsdfCosine = material.eval(surface, connection.direction, rng);
    connection.incidentRadiance = light.evalLi(surface.posW, rng) * float(visible);
    return connection;
}

// Submit one completed-path candidate. Keep the Monte Carlo
// contribution, the area target, and the RIS selection weight distinct.
void submitCandidate(inout Reservoir reservoir, ReconnectionState rc,
    ShadingData surface, IMaterialInstance material, LightSample light,
    DirectConnection connection, float3 throughput, inout SampleGenerator rng)
{
    float3 contribution = throughput * connection.bsdfCosine * connection.incidentRadiance * connection.gate;
    float3 target = rc.bounce > 0 ? contribution * rc.areaPdf : contribution;
    float selectionWeight = getReservoirWeight(contribution) / float(samplesPerPixel);
    if (!(selectionWeight > 0.f) || !isfinite(selectionWeight) ||
        !all(isfinite(target)) || !(getReservoirWeight(target) > 0.f)) return;
    if (!reservoir.update(target, selectionWeight, 1, rng)) return;

    reservoir.totalPathLength = connection.totalLength;
    reservoir.rcVertexBounce = rc.bounce;
    if (rc.bounce == 0) return; // Reconnection fields are unused for this local-only sample.

    reservoir.rcNextVertexBounce = rc.postBounce;
    reservoir.rcVertexHit = rc.xHit;
    reservoir.initRandomSeed = rc.prefixSeed;
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
}

// The same completed path is a candidate for every gate it overlaps.
// Box bins are disjoint, so that common case updates only one reservoir.
void submitHistogramCandidate(uint pixelIndex, ReconnectionState rc, ShadingData surface,
    IMaterialInstance material, LightSample light, DirectConnection connection,
    float3 throughput, inout SampleGenerator rng)
{
    uint firstBin = 0;
    uint endBin = tbin;
    if (time_gate_mode == kTimeGateBox)
    {
        if (!(connection.totalLength >= tmin && connection.totalLength < tmax)) return;
        firstBin = min(uint((connection.totalLength - tmin) / tunit), tbin - 1);
        endBin = firstBin + 1;
    }
    for (uint bin = firstBin; bin < endBin; ++bin)
    {
        float center = tmin + (float(bin) + 0.5f) * tunit;
        // Half-open box bins assign boundary samples exactly once.
        connection.gate = time_gate_mode == kTimeGateBox ? 1.f : pathLengthImportance(connection.totalLength, center);
        if (!(connection.gate > 0.f)) continue;
        uint index = pixelIndex * tbin + bin;
        Reservoir reservoir = currReservoirs[index];
        submitCandidate(reservoir, rc, surface, material, light, connection, throughput, rng);
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
                lightSampler.generateLightSample(lightRng, light);
                DirectConnection connection = evaluateDirectConnection(surface, material, light, pathLength, rng);
                submitHistogramCandidate(pixelIndex, rc, surface, material, light, connection, throughput, rng);
            }
            if (rc.bounce > 0) ++rc.postBounce;
            if (depth + 1 >= MAX_BOUNCES) break;

            bool previousDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            BSDFSample sample = {};
            if (!material.sample(surface, bsdfRng, sample, USE_IMPORTANCE_SAMPLING)) break;
            throughput *= sample.weight;
            float suffixDirectionWeight = 0.f;
            if (rc.postBounce == 2 && sample.pdf > 0.f)
                suffixDirectionWeight = shadingCosine(surface, material, sample.wo) / sample.pdf;

            float3 previousPosition = surface.posW;
            float3 origin = surface.computeRayOrigin(!sample.isLobe(LobeType::Transmission));
            SceneRayQuery<USE_ALPHA_TEST> query;
            float hitT;
            HitInfo hit = query.traceRay(Ray(origin, sample.wo, 0.f, FLT_MAX), hitT);
            if (!hit.isValid()) break;
            surface = loadShadingData(hit, origin, sample.wo);
            material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            float segmentLength = length(surface.posW - previousPosition);
            // Match time-gated generation and shared prefix replay.
            pathLength += segmentLength * surface.IoR;
            bool currentDiffuse = material.getProperties(surface).roughness > specularRoughnessThreshold;
            rc.recordHit(hit, surface, sample, depth + 1,
                previousDiffuse && currentDiffuse && segmentLength > 0.f,
                segmentLength, suffixDirectionWeight);
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
