import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.ShiftMapping.PathLengthAwareShiftmapping;
import RenderPasses.Shared.Shaders.Antithetic.AntitheticMIS;
import RenderPasses.Shared.Shaders.Utils.Waveform;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.

    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;

    uint samplesPerPixel;
}

cbuffer Modulation
{
    float gModulationWavelength; // Path length of one period.
    float gModulationPhase;      // Sensor phase offset, in periods.
    uint gWaveform;              // WAVEFORM_*.
    uint gUnsignedModulation;    // Weight 0.5 w + 0.5 instead of w.
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

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRoundTripTolerance = 0.01f; // Round-trip error allowed, relative to the shift distance.


/// Position of a path of optical length `pathLength` in the modulation, in periods.
float modulationPeriods(float pathLength)
{
    return pathLength / gModulationWavelength - gModulationPhase;
}

/// Weight of a path of optical length `pathLength`.
float modulationWeight(float pathLength)
{
    float weight = evalWaveform(gWaveform, modulationPeriods(pathLength));
    return gUnsignedModulation != 0 ? 0.5f * weight + 0.5f : weight;
}

// Connection of `surface` to the light, weighted by the modulation of the whole path.
// `pathLength` is the optical length from the camera to `surface`; `totalLength` returns that of the whole path.
float3 evaluateModulatedConnection(ShadingData surface, IMaterialInstance material, LightSample light,
    float pathLength, inout SampleGenerator sg, out float totalLength)
{
    LightConnection connection = evaluateLightConnection(surface, material, light, sg);
    totalLength = pathLength + connection.distance + light.laserT;
    return connection.bsdfCosine * connection.incidentRadiance * modulationWeight(totalLength);
}

// The light endpoint as a vertex of the shift mapping.
ShadingData getLightEndpoint(LightSample light)
{
#if IS_LIGHT_SOURCE_LASER
    return light.sd;
#else
    ShadingData endpoint = {};
    endpoint.posW = light.origin;
    endpoint.frontFacing = true;
    endpoint.faceN = light.dir;
    return endpoint;
#endif
}

/** Estimate of the BSDF-sampled segment previous -> surface and its antithetic partner, including the connection
    of each to the light (AntitheticMIS). The partner moves `surface` on its surface so the path length changes by
    antitheticWaveformOffset(), which flips the sign of the waveform: half a wavelength longer or shorter with equal
    probability (two inverse shifts), or the sawtooth's mirror (its own inverse). Without a partner (e.g. the
    Newton solve fails), the primal estimate is returned alone.
    @param[in] primalEstimate throughput * f / p of the primal path, connected to the light.
    @param[in] primalLength Optical length of the whole primal path.
    @param[in] prefixLength Optical length from the camera to `previous`.
*/
float3 estimateWithAntithetic(ShadingData previous, IMaterialInstance previousMaterial, HitInfo hit, ShadingData surface,
    BSDFSample bsdfSample, LightSample light, float3 throughput, float3 primalEstimate, float primalLength,
    float prefixLength, inout SampleGenerator sg)
{
    float dt = antitheticWaveformOffset(gWaveform, modulationPeriods(primalLength), sampleNext1D(sg)) * gModulationWavelength;
    if (!light.valid || bsdfSample.isLobe(LobeType::Delta) || !(bsdfSample.pdf > 0.f)) return primalEstimate;
    if (hit.getType() != HitType::Triangle) return primalEstimate;

    // The shifted vertex is traced from `previous`, so it is the first hit in its direction, as a BSDF sample
    // from `previous` would be. The light endpoint stays fixed.
    float areaJacobian = 0.f;
    ShiftMapDebugInfo debugInfo = {};
    float tolerance = max(abs(dt) * gNewtonRelativeTolerance, 1e-6f);
    HitInfo shiftedHit = path_length_aware_shift_mapping(getLightEndpoint(light), hit, previous, dt, areaJacobian,
        debugInfo, tolerance, sg);
    if (!(areaJacobian > 0.f) || !isfinite(areaJacobian)) return primalEstimate;
    float3 shiftedPosition = gScene.getVertexData(shiftedHit.getTriangleHit()).posW;

#if ANTITHETIC_ROUND_TRIP_CHECK
    // Keep the shift only if shifting the partner back (-dt) returns to `surface`. Where it is kept, the forward and
    // backward shifts are then exact inverses and one-to-one, as AntitheticMIS needs, even when the Newton solve
    // could land elsewhere (e.g. on another surface with the ray-trace charts).
    float reverseJacobian = 0.f;
    HitInfo returnedHit = path_length_aware_shift_mapping(getLightEndpoint(light), shiftedHit, previous, -dt,
        reverseJacobian, debugInfo, tolerance, sg);
    if (!(reverseJacobian > 0.f) || !isfinite(reverseJacobian)) return primalEstimate;
    float3 returnedPosition = gScene.getVertexData(returnedHit.getTriangleHit()).posW;
    if (length(returnedPosition - surface.posW) > kRoundTripTolerance * length(shiftedPosition - surface.posW))
        return primalEstimate;
#endif

    float3 toShifted = shiftedPosition - previous.posW;
    float shiftedDistance = length(toShifted);
    float3 shiftedDir = toShifted / shiftedDistance;
    ShadingData shifted = loadShadingData(shiftedHit, previous.posW, shiftedDir);
    let shiftedMaterial = gScene.materials.getMaterialInstance(shifted, ExplicitLodTextureSampler(0.f));

    // Area Jacobian -> solid angle at `previous`: |dw_a / dw| = (G_a / G) * |dA_a / dA|, G = cos / distance^2.
    float primalDistance = length(surface.posW - previous.posW);
    float primalGeometry = abs(dot(surface.getOrientedFaceNormal(), bsdfSample.wo)) / (primalDistance * primalDistance);
    float shiftedGeometry = abs(dot(shifted.getOrientedFaceNormal(), shiftedDir)) / (shiftedDistance * shiftedDistance);
    if (!(primalGeometry > 1e-9f) || !(shiftedGeometry > 1e-9f)) return primalEstimate;
    float jacobian = shiftedGeometry / primalGeometry * areaJacobian;

    float antitheticBsdfPdf = previousMaterial.evalPdf(previous, shiftedDir, kUseImportanceSampling);
    float antitheticLength;
    float3 antitheticValue = throughput * previousMaterial.eval(previous, shiftedDir, sg) *
        evaluateModulatedConnection(shifted, shiftedMaterial, light, prefixLength + shiftedDistance * previous.IoR, sg,
            antitheticLength);
    return combineAntithetic(primalEstimate, bsdfSample.pdf, antitheticValue, antitheticBsdfPdf, jacobian);
}

// Trace camera paths and connect each vertex to a sampled laser endpoint.
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
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);

        for (uint i = 0; i < samplesPerPixel; i++)
        {
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);

            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            float pathLength = length(sd.posW - primaryRayOrigin);
            HitInfo hit = hit0;

            // Direct illumination at the primary hit (camera -> primary -> light). The primary hit comes from
            // the V-buffer, not from a BSDF sample, so it has no antithetic partner.
            if (kComputeDirect)
            {
                LightSample ls = {};
                lls.generateLightSample(sg, ls);
                float totalLength;
                result += throughput * evaluateModulatedConnection(sd, mi, ls, pathLength, sg, totalLength);
            }

            for (uint depth = 1; depth < kMaxBounces; depth++)
            {
                BSDFSample bsdfSample = {};
                if (!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)) break;

                ShadingData previous = sd;
                IMaterialInstance previousMaterial = mi;
                bool transmission = bsdfSample.isLobe(LobeType::Transmission);
                float3 rayOrigin = sd.computeRayOrigin(!transmission);
                float hitT;
                hit = traceRay(rayOrigin, bsdfSample.wo, hitT);
                if (!hit.isValid()) break;

                sd = loadShadingData(hit, rayOrigin, bsdfSample.wo);
                mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                float segmentLength = length(sd.posW - previous.posW) * previous.IoR;

                LightSample ls = {};
                lls.generateLightSample(sg, ls);
                float primalLength;
                float3 primalEstimate = throughput * bsdfSample.weight *
                    evaluateModulatedConnection(sd, mi, ls, pathLength + segmentLength, sg, primalLength);
#if USE_ANTITHETIC_SAMPLING
                result += estimateWithAntithetic(previous, previousMaterial, hit, sd, bsdfSample, ls, throughput,
                    primalEstimate, primalLength, pathLength, sg);
#else
                result += primalEstimate;
#endif

                throughput *= bsdfSample.weight;
                pathLength += segmentLength;
                if (!any(throughput > 0.f) || any(throughput < 0.f)) break;
            }
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
