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
// Doppler time-of-flight, low-pass model: at time t, a path x of optical length l(x, t) (m) is weighted by
//     w(t, l) = cos(2 pi (df t - f_g l / c - phase)),
// the low-passed product of the light modulation (f_g) and the sensor modulation (f_g - df). The host has moved the
// scene to its pose at t; this pass traces every pixel's paths there and adds f w / spp, times gTimeWeight, to the
// output (written by the first time of the frame, added by its antithetic partner, which uses the same seed).
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Lights.Laser;

cbuffer CB
{
    uint2 gFrameDim;
    uint gSeedFrame;           // The same for both times of a frame: random replay.
    uint gSamplesPerPixel;
    float gModulationFrequency; // f_g, Hz
    float gHeterodyneFrequency; // df, Hz
    float gPhase;               // periods
    float gTime;                // s
    float gTimeWeight;          // 1 / number of times in the frame
    bool gAddToOutput;
}

RWTexture2D<float4> gOutputColor;

static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const float kSpeedOfLight = 299792458.f;

float modulationWeight(float pathLength)
{
    float cycles = frac(gHeterodyneFrequency * gTime) - frac(gModulationFrequency / kSpeedOfLight * pathLength) - gPhase;
    return cos(M_2PI * cycles);
}

float3 tracePath(const uint2 pixel)
{
    // The pixel-center camera ray, traced in the scene at time t.
    Ray cameraRay = gScene.camera.computeRayPinhole(pixel, gFrameDim, false);
    float hitT;
    HitInfo primaryHit = traceRay(cameraRay.origin, cameraRay.dir, hitT);
    if (!primaryHit.isValid()) return float3(0.f);
    ShadingData primary = loadShadingData(primaryHit, cameraRay.origin, cameraRay.dir);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gSeedFrame, kPathSampleStream);
    LaserLightSampler lightSampler = createLaserLightSampler();
    float3 measurement = 0.f;
    for (uint sample = 0; sample < gSamplesPerPixel; ++sample)
    {
        ShadingData surface = primary;
        float pathLength = length(primary.posW - cameraRay.origin);
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
                    float totalLength = pathLength + connection.distance + light.laserT;
                    measurement += throughput * connection.bsdfCosine * connection.incidentRadiance *
                                   modulationWeight(totalLength);
                }
            }
            if (depth + 1 >= kMaxBounces) break;
            BSDFSample bsdfSample = {};
            if (!material.sample(surface, sg, bsdfSample, kUseImportanceSampling)) break;
            throughput *= bsdfSample.weight;
            float3 origin = surface.computeRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
            HitInfo hit = traceRay(origin, bsdfSample.wo, hitT);
            if (!hit.isValid()) break;
            ShadingData next = loadShadingData(hit, origin, bsdfSample.wo);
            pathLength += length(next.posW - surface.posW) * surface.IoR;
            surface = next;
        }
    }
    return measurement / gSamplesPerPixel;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    float3 value = tracePath(pixel) * gTimeWeight;
    if (gAddToOutput) value += gOutputColor[pixel].xyz;
    gOutputColor[pixel] = float4(value, 1.f);
}
