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
// Doppler spectrum of optical heterodyne detection with a single-frequency laser (OHD path integral, Kim et al. 2025,
// Eq. 26 with B = 0): every path adds its contribution to the bin of its Doppler frequency shift
//     df(x) = f0 u(x) / c = u(x) / wavelength,
// where the path velocity u(x) = sum_k eta_k (v_k - v_{k+1}) . d_k (Eq. 32) sums, over the segments x_k -> x_{k+1}
// (from the light towards the camera), the velocity of their endpoints along the segment. It is positive when the
// path shortens (e.g. an object approaching a collocated camera and light). Vertices do not move: their instantaneous
// velocities only select the bin; the contribution is that of the static path.
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Lights.Laser;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gSamplesPerPixel;

    float gFrequencyMin;     // MHz
    float gFrequencyBinWidth;         // MHz
    uint gFrequencyBin;
    float gShiftPerVelocity; // MHz per m/s: 1 / wavelength.
    float3 gSensorVelocity;  // m/s
    float3 gLightVelocity;   // m/s
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Instantaneous rigid motion of each geometry instance: v(x) = linear + angular x (x - center).
struct InstanceVelocity
{
    float4 linear;
    float4 angular;
    float4 center;
};
StructuredBuffer<InstanceVelocity> gInstanceVelocities;

// Outputs
RWTexture2D<float4> gOutputColor;
RWTexture3D<HistogramTexel> gSpectrum;

// Static configuration based on defines set from the host.
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;

// Velocity of the scene surface point posW, hit by `hit`.
float3 surfaceVelocity(HitInfo hit, float3 posW)
{
    if (!hit.isValid() || hit.getType() != HitType::Triangle) return float3(0.f);
    InstanceVelocity motion = gInstanceVelocities[hit.getInstanceID().index];
    return motion.linear.xyz + cross(motion.angular.xyz, posW - motion.center.xyz);
}

// Path-velocity term of the segment between q (the light side) and p (the camera side), with refractive index eta:
// eta (v_q - v_p) . (p - q) / |p - q|.
float segmentVelocity(float3 p, float3 vp, float3 q, float3 vq, float eta)
{
    float3 d = p - q;
    float len = length(d);
    return len > 0.f ? eta * dot(vq - vp, d / len) : 0.f;
}

// Path-velocity terms of the connection from surface point s (velocity vs) to the light: to the laser spot and on to
// the laser origin, or to the point light.
float connectionVelocity(float3 s, float3 vs, LightSample light, float3 lightOrigin)
{
#if IS_LIGHT_SOURCE_LASER
    float3 spot = light.posW();
    float3 vSpot = surfaceVelocity(light.hit, spot);
    return segmentVelocity(s, vs, spot, vSpot, 1.f) + segmentVelocity(spot, vSpot, lightOrigin, gLightVelocity, 1.f);
#else
    return segmentVelocity(s, vs, light.posW(), gLightVelocity, 1.f);
#endif
}

// Spectrum values are radiance density per unit frequency (MHz), summed across frames.
void accumulateToSpectrum(uint2 pixel, float shift, float3 radiance)
{
    float coordinate = (shift - gFrequencyMin) / gFrequencyBinWidth;
    // Half-open range [frequencyMin, frequencyMax).
    if (!(coordinate >= 0.f && coordinate < float(gFrequencyBin))) return;
    uint bin = min(uint(coordinate), gFrequencyBin - 1);
    gSpectrum[uint3(pixel, bin)] += toHistogramTexel(radiance / (gFrequencyBinWidth * gSamplesPerPixel));
}

// Each pixel owns all of its bins, so spectrum updates require no atomics.
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return float3(0.f);
    float3 cameraOrigin = gScene.camera.getPosition();
    ShadingData primary = loadShadingData(primaryHit, cameraOrigin, getPrimaryRayDir(pixel, frameDim, gViewW));
    float3 primaryVelocity = surfaceVelocity(primaryHit, primary.posW);
    // The camera segment (primary hit -> camera), in air.
    float primarySegment = segmentVelocity(cameraOrigin, gSensorVelocity, primary.posW, primaryVelocity, 1.f);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);
    LaserLightSampler lightSampler = createLaserLightSampler();
    float3 radiance = 0.f;
    for (uint sample = 0; sample < gSamplesPerPixel; ++sample)
    {
        ShadingData surface = primary;
        float3 velocity = primaryVelocity;
        float pathVelocity = primarySegment; // Of the camera path so far, m/s.
        float3 throughput = 1.f;
        // As the transient histogram path tracer: the primary vertex is depth zero.
        for (uint depth = 0; depth < max(1u, kMaxBounces) && any(throughput > 0.f); ++depth)
        {
            IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            if (depth > 0 || kComputeDirect)
            {
                LightSample light = {};
                lightSampler.generateLightSample(sg, light);
                if (light.valid)
                {
                    LightConnection connection = evaluateLightConnection(surface, material, light, sg);
                    float3 contribution = throughput * connection.bsdfCosine * connection.incidentRadiance;
                    radiance += contribution;
                    float totalVelocity =
                        pathVelocity + connectionVelocity(surface.posW, velocity, light, lightSampler.laserOrigin);
                    accumulateToSpectrum(pixel, totalVelocity * gShiftPerVelocity, contribution);
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
            float3 nextVelocity = surfaceVelocity(hit, next.posW);
            // As the optical path length: the segment's refractive index is that of the surface it leaves.
            pathVelocity += segmentVelocity(surface.posW, velocity, next.posW, nextVelocity, surface.IoR);
            surface = next;
            velocity = nextVelocity;
        }
    }
    return radiance / gSamplesPerPixel;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    gOutputColor[pixel] = float4(tracePath(pixel, gFrameDim), 1.f);
}
