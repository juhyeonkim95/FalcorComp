// Doppler-gated image of optical heterodyne detection with a single-frequency laser: the light whose Doppler
// frequency shift falls in a gate, as DopplerHistogramPathTracerInline's spectrum is the light at each shift (OHD path
// integral, Kim et al. 2025, Eq. 26 with B = 0). Every path is weighted by the gate kernel at its shift
//     df(x) = u(x) / wavelength,
// with the path velocity u(x) of DopplerHistogramPathTracerInline. The kernels are the time-gate kernels of
// TimeGate.slang over the shift instead of the path length: gTimeCenter is the gate center and gTimeGateWindow its
// width, in MHz. As in the time-gated path tracer, the image is divided by the width: radiance per MHz.
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.PathVelocity;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.TimeGate;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Lights.Laser;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount; // Frame count since scene was loaded.
    uint gSamplesPerPixel;
    float gShiftPerVelocity; // MHz per m/s: 1 / wavelength.
    float3 gSensorVelocity;  // m/s
    float3 gLightVelocity;   // m/s
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

float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return float3(0.f);
    float3 cameraOrigin = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraOrigin, getPrimaryRayDir(pixel, frameDim, gViewW));
    float3 primaryVelocity = surfaceVelocity(primaryHit, primary.posW);
    // The camera segment (primary hit -> camera), in air.
    float primarySegment = segmentVelocity(cameraOrigin, gSensorVelocity, primary.posW, primaryVelocity);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);
    LaserLightSampler lightSampler = createLaserLightSampler();
    float3 radiance = 0.f;
    for (uint sample = 0; sample < gSamplesPerPixel; ++sample)
    {
        ShadingData surface = primary;
        float3 velocity = primaryVelocity;
        float pathVelocity = primarySegment; // Of the camera path so far, m/s.
        float3 throughput = 1.f;
        // As the Doppler histogram path tracer: the primary vertex is depth zero.
        for (uint depth = 0; depth < kMaxBounces && any(throughput > 0.f); ++depth)
        {
            IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            if ((depth > 0 || kComputeDirect) && hasNonDeltaLobe(surface, material))
            {
                LightSample light = {};
                lightSampler.generateLightSample(sg, light);
                bool connected;
                LightConnection connection = connectToLight(surface, light, connected);
                if (connected)
                {
                    float shift = (pathVelocity + connectionVelocity(surface.posW, velocity, light, lightSampler.laserOrigin, gLightVelocity)) *
                                  gShiftPerVelocity;
                    float gate = pathLengthImportance(shift, gTimeCenter);
                    // Outside the gate the connection contributes zero: skip its visibility ray and BSDF.
                    if (gate != 0.f)
                    {
                        shadeLightConnection(connection, surface, material, light, sg);
                        radiance += throughput * connection.bsdfCosine * connection.incidentRadiance * gate;
                    }
                }
            }
            if (depth + 1 >= kMaxBounces) break;
            BSDFSample bsdfSample = {};
            if (!material.sample(surface, sg, bsdfSample, kUseImportanceSampling)) break;
            throughput *= bsdfSample.weight;
            float3 origin = surface.computeRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
            float hitT;
            HitInfo hit = traceRay(origin, bsdfSample.wo, hitT);
            if (!hit.isValid()) break;
            ShadingData next = loadShadingData(hit, origin, bsdfSample.wo);
            float3 nextVelocity = surfaceVelocity(hit, next.posW);
            // As the optical path length: the segment's refractive index is that of the surface it leaves.
            pathVelocity += segmentVelocity(surface.posW, velocity, next.posW, nextVelocity, surface.IoR);
            surface = next;
            velocity = nextVelocity;
        }
    }
    radiance /= gSamplesPerPixel;
    return any(isinf(radiance) || isnan(radiance)) ? float3(0.f) : radiance;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    float3 color = tracePath(pixel, gFrameDim);
#if USE_SINGLE_CHANNEL
    color = float3(selectChannel(color));
#endif
    gOutputColor[pixel] = float4(color / gTimeGateWindow, 1.f);
}
