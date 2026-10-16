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
// Power spectrum of optical heterodyne detection (OHD path integral, Kim et al. 2025, Eq. 26): every path adds its
// contribution to the bin of its frequency.
// - Single-frequency laser (B = 0): the Doppler frequency shift
//       f_D(x) = f0 u(x) / c = u(x) / wavelength,
//   where the path velocity u(x) = sum_k eta_k (v_k - v_{k+1}) . d_k (Eq. 32) sums, over the segments x_k -> x_{k+1}
//   (from the light towards the camera), the velocity of their endpoints along the segment. It is positive when the
//   path shortens (e.g. an object approaching a collocated camera and light).
// - Linear chirp (FMCW, CHIRPED): the laser sweeps by B over T, up and then down (a triangular chirp). The beat
//   frequency also has a range term f_R(x) = B / T * l(x) / c, with l(x) the optical path length (Eq. 33): it is
//   f_R - f_D on the up-chirp (gSpectrum) and f_R + f_D on the down-chirp (gSpectrumDown) (Eq. 9).
// Vertices do not move: their instantaneous velocities only select the bin; the contribution is that of the static
// path.
// With USE_VOLUMES, paths also scatter in participating media (Shared/Shaders/Volumes/Media.slang): the scattering
// events are vertices like the surfaces, and their scatterers move with their medium's instance.
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.Utils.PathVelocity;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Lights.Laser;
#ifndef USE_VOLUMES
#define USE_VOLUMES 0 // Set by the host (VolumeConfig).
#endif
#if USE_VOLUMES
import RenderPasses.Shared.Shaders.Volumes.Media;
import Rendering.Volumes.PhaseFunction;
#endif

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gSamplesPerPixel;

    float gFrequencyMin;     // MHz
    float gFrequencyBinWidth;         // MHz
    uint gFrequencyBin;
    float gShiftPerVelocity; // MHz per m/s: 1 / wavelength.
    float gRangeFrequencyPerLength; // MHz per meter of optical path length: B / (T c) (CHIRPED).
    float3 gSensorVelocity;  // m/s
    float3 gLightVelocity;   // m/s
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;
RWTexture3D<HistogramTexel> gSpectrum;
#if CHIRPED
RWTexture3D<HistogramTexel> gSpectrumDown;
#endif

// Static configuration based on defines set from the host.
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;

// The bin of `frequency` in the half-open range [frequencyMin, frequencyMax); false outside it.
bool frequencyBin(float frequency, out uint bin)
{
    float coordinate = (frequency - gFrequencyMin) / gFrequencyBinWidth;
    bin = 0;
    if (!(coordinate >= 0.f && coordinate < float(gFrequencyBin))) return false;
    bin = min(uint(coordinate), gFrequencyBin - 1);
    return true;
}

// Adds a path with optical length `pathLength` (m) and path velocity `pathVelocity` (m/s) to the spectra, its Doppler
// shift offset by `offset` (MHz). Spectrum values are radiance density per unit frequency (MHz), summed across frames.
void accumulateToSpectrum(uint2 pixel, float pathLength, float pathVelocity, float3 radiance, float offset = 0.f)
{
    if (all(radiance == 0.f)) return; // E.g. a blocked connection: no texel to update.
    HistogramTexel value = toHistogramTexel(radiance / (gFrequencyBinWidth * gSamplesPerPixel));
    float doppler = pathVelocity * gShiftPerVelocity + offset; // f_D
    uint bin;
#if CHIRPED
    float range = pathLength * gRangeFrequencyPerLength; // f_R
    if (frequencyBin(range - doppler, bin)) gSpectrum[uint3(pixel, bin)] += value;
    if (frequencyBin(range + doppler, bin)) gSpectrumDown[uint3(pixel, bin)] += value;
#else
    if (frequencyBin(doppler, bin)) gSpectrum[uint3(pixel, bin)] += value;
#endif
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
    float primarySegment = segmentVelocity(cameraOrigin, gSensorVelocity, primary.posW, primaryVelocity);
    float primaryLength = length(primary.posW - cameraOrigin);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);
    LaserLightSampler lightSampler = createLaserLightSampler();
    float3 radiance = 0.f;
    for (uint sample = 0; sample < gSamplesPerPixel; ++sample)
    {
        ShadingData surface = primary;
        float3 velocity = primaryVelocity;
        float pathVelocity = primarySegment; // Of the camera path so far, m/s.
        float pathLength = primaryLength;    // Optical length of the camera path so far, m.
        float3 throughput = 1.f;
        // As the transient histogram path tracer: the primary vertex is depth zero.
        for (uint depth = 0; depth < kMaxBounces && any(throughput > 0.f); ++depth)
        {
            IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            if ((depth > 0 || kComputeDirect) && hasNonDeltaLobe(surface, material))
            {
                LightSample light = {};
                lightSampler.generateLightSample(sg, light);
                if (light.valid)
                {
                    LightConnection connection = evaluateLightConnection(surface, material, light, sg);
                    float3 contribution = throughput * connection.bsdfCosine * connection.incidentRadiance;
                    radiance += contribution;
                    float totalVelocity =
                        pathVelocity + connectionVelocity(surface.posW, velocity, light, lightSampler.laserOrigin, gLightVelocity);
                    // The connection to the light, in air, and on to the laser origin.
                    float totalLength = pathLength + connection.distance + light.laserT;
                    accumulateToSpectrum(pixel, totalLength, totalVelocity, contribution);
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
            pathLength += length(next.posW - surface.posW) * surface.IoR;
            surface = next;
            velocity = nextVelocity;
        }
    }
    return radiance / gSamplesPerPixel;
}

#if USE_VOLUMES
static const uint kMaxScatterEvents = MAX_SCATTER_EVENTS;
static const uint kRussianRouletteStart = 8; // Scattering events before Russian roulette.
static const uint kMaxInterfaceEvents = 64;  // Reflections and refractions at medium boundaries on a path.

// Half width at half maximum (MHz) of the Lorentzian line of a path through diffusing (Brownian) scatterers, from
// brownian = sum over its scattering events of n^2 D (1 - cos theta). Its field correlation decays as exp(-Gamma tau),
// Gamma = sum q^2 D with q = 2 k sin(theta / 2), k = 2 pi n / lambda (independent scatterers): Gamma / (2 pi) =
// 4 pi brownian / lambda^2.
float brownianHalfWidth(float brownian)
{
    float perLength = gShiftPerVelocity * 1e6f; // 1 / lambda, per meter
    return 4.f * M_PI * brownian * perLength * perLength * 1e-6f;
}

// Adds the light connection `c` of a vertex to the radiance and the spectra: `scatter` is the vertex's BSDF times
// cosine, or phase function, for the connection's direction; `brownian` that of the path (brownianHalfWidth), whose
// Lorentzian line is sampled.
void addLightConnection(uint2 pixel, MediumLightConnection c, float3 throughput, float3 scatter, float3 irradiance,
    float pathLength, float pathVelocity, float brownian, inout float3 radiance, inout SampleGenerator sg)
{
    float3 contribution = throughput * scatter * irradiance;
    if (all(contribution == 0.f)) return;
    radiance += contribution;
    float offset = brownian > 0.f ? brownianHalfWidth(brownian) * tan(M_PI * (sampleNext1D(sg) - 0.5f)) : 0.f;
    accumulateToSpectrum(pixel, pathLength + c.length, pathVelocity + c.pathVelocity, contribution, offset);
}

// tracePath through participating media: between vertices, a camera ray may cross medium boundaries and scatter in a
// medium (traceThroughMedia). A scattering event is a vertex: it connects to the light through the medium's phase
// function and continues in a direction sampled from it. A refracting medium boundary is a vertex too: the path
// reflects or refracts there, chosen by the Fresnel reflectance, and a refraction from index n1 into n2 weighs
// (n1 / n2)^2 (radiance). Light connections go through media (connectToLightInMedia), refracted once at most. Diffusing
// scatterers (InstanceVelocity.diffusion) broaden a path's line to a Lorentzian (addLightConnection).
// Without media in the scene, this renders what tracePath renders, with the same random numbers.
float3 tracePathInMedia(const uint2 pixel, const uint2 frameDim)
{
    HitInfo primaryHit = HitInfo(gVBuffer[pixel]);
    if (!primaryHit.isValid()) return float3(0.f);
    float3 cameraOrigin = gScene.camera.getPosition();
    float3 primaryDir = getPrimaryRayDir(pixel, frameDim, gViewW);
    SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);
    LaserLightSampler lightSampler = createLaserLightSampler();
    float3 radiance = 0.f;
    for (uint sample = 0; sample < gSamplesPerPixel; ++sample)
    {
        MediumStack media = createEmptyMediumStack(); // The camera is outside every medium.
        float3 throughput = 1.f;
        float3 vertex = cameraOrigin; // The last vertex of the camera path, its velocity, and the refractive index
        float3 vertexVelocity = gSensorVelocity; // of the medium that the segment leaving it crosses.
        float vertexIoR = 1.f;
        float pathVelocity = 0.f; // Of the camera path so far, m/s.
        float pathLength = 0.f;   // Optical length of the camera path so far, m.
        float brownian = 0.f;     // Sum of n^2 D (1 - cos theta) over its scattering events so far (brownianHalfWidth).
        float3 dir = primaryDir;
        uint surfaceDepth = 0;    // As in tracePath: the primary hit is depth zero.
        uint scatterEvents = 0;
        uint interfaceEvents = 0;

        // The first event: the primary hit, a refracting boundary there, or what lies past an index-matched one.
        MediumEvent event = {};
        event.type = MediumEventType::Surface;
        event.hit = primaryHit;
        event.origin = cameraOrigin;
        MediumBoundary boundary;
        if (getMediumBoundary(primaryHit, dir, media, boundary))
        {
            float3 position = loadShadingData(primaryHit, cameraOrigin, dir).posW;
            if (boundary.isIndexMatched())
            {
                media.cross(boundary.instance, boundary.entering);
                event = traceThroughMedia(position, boundary.rayOrigin(position, dir), dir, media, throughput, sg);
            }
            else
            {
                event.type = MediumEventType::Interface;
                event.position = position;
                event.boundary = boundary;
            }
        }

        while (any(throughput > 0.f) && event.type != MediumEventType::Escape)
        {
            if (event.type == MediumEventType::Interface)
            {
                // Reflection or refraction at a medium boundary: a vertex, which moves with its instance.
                if (++interfaceEvents > kMaxInterfaceEvents) break;
                MediumBoundary b = event.boundary;
                float3 position = event.position;
                float3 velocity = gInstanceVelocities[b.instance].at(position);
                pathVelocity += segmentVelocity(vertex, vertexVelocity, position, velocity, vertexIoR);
                pathLength += length(position - vertex) * vertexIoR;
                float3 normal = dot(b.faceNormal, dir) < 0.f ? b.faceNormal : -b.faceNormal; // Facing the ray.
                float cosI = -dot(dir, normal);
                bool refracted = sampleNext1D(sg) >= fresnelDielectric(cosI, b.n2 / b.n1);
                float3 wo = refracted ? refract(dir, normal, b.n1 / b.n2) : reflect(dir, normal);
                if (refracted)
                {
                    media.cross(b.instance, b.entering);
                    throughput *= (b.n1 / b.n2) * (b.n1 / b.n2);
                }
                vertex = position;
                vertexVelocity = velocity;
                vertexIoR = media.ior();
                dir = wo;
                event = traceThroughMedia(position, b.rayOrigin(position, dir), dir, media, throughput, sg);
                continue;
            }

            if (event.type == MediumEventType::Scatter)
            {
                float3 position = event.position;
                InstanceVelocity motion = gInstanceVelocities[media.innermost()];
                // The scatterer: the medium's, or blood in its vessels (Vessels).
                float3 velocity = event.blood ? vesselVelocity(position) : motion.at(position);
                pathVelocity += segmentVelocity(vertex, vertexVelocity, position, velocity, vertexIoR);
                pathLength += length(position - vertex) * vertexIoR;
                VolumeProperties vp = media.properties();
                float n = media.ior();
                float diffusion = (event.blood ? gBloodDiffusion : motion.diffusion.x) * n * n;
                if (event.blood) vp.phaseFunction = HenyeyGreensteinPhaseFunction(gBloodAnisotropy);

                LightSample light = {};
                lightSampler.generateLightSample(sg, light);
                MediumLightConnection c = connectToLightInMedia(position, position, velocity, media, light,
                    gLightVelocity, sg);
                if (c.connected)
                {
                    float3 phase = vp.phaseFunction.eval(-dir, c.direction);
                    addLightConnection(pixel, c, throughput, phase, c.evalIrradiance(light, position, sg), pathLength,
                        pathVelocity, brownian + diffusion * (1.f - dot(dir, c.direction)), radiance, sg);
                }

                if (++scatterEvents >= kMaxScatterEvents) break;
                if (scatterEvents >= kRussianRouletteStart)
                {
                    float survival = min(max(throughput.r, max(throughput.g, throughput.b)), 0.95f);
                    if (sampleNext1D(sg) >= survival) break;
                    throughput /= survival;
                }
                float3 wo;
                float pdf;
                float3 weight;
                if (!vp.phaseFunction.sample(-dir, wo, pdf, weight, sg)) break;
                throughput *= weight;
                brownian += diffusion * (1.f - dot(dir, wo));
                vertex = position;
                vertexVelocity = velocity;
                vertexIoR = media.ior();
                dir = wo;
                event = traceThroughMedia(position, position, dir, media, throughput, sg);
                continue;
            }

            // A surface vertex, as in tracePath.
            if (surfaceDepth >= kMaxBounces) break;
            ShadingData surface = loadShadingData(event.hit, event.origin, dir);
            float3 velocity = surfaceVelocity(event.hit, surface.posW);
            pathVelocity += segmentVelocity(vertex, vertexVelocity, surface.posW, velocity, vertexIoR);
            pathLength += length(surface.posW - vertex) * vertexIoR;
            IMaterialInstance material = gScene.materials.getMaterialInstance(surface, ExplicitLodTextureSampler(0.f));
            // computeDirect decides only for the path's first vertex: camera -> primary hit -> light.
            bool firstVertex = surfaceDepth == 0 && scatterEvents == 0 && interfaceEvents == 0;
            if ((!firstVertex || kComputeDirect) && hasNonDeltaLobe(surface, material))
            {
                LightSample light = {};
                lightSampler.generateLightSample(sg, light);
                MediumLightConnection c = connectToLightInMedia(rayOriginToward(surface, light.posW() - surface.posW),
                    surface.posW, velocity, media, light, gLightVelocity, sg);
                float3 bsdfCosine = 0.f;
                float3 irradiance = 0.f;
                if (c.connected)
                {
                    bsdfCosine = material.eval(surface, c.direction, sg);
                    irradiance = c.evalIrradiance(light, surface.posW, sg);
                }
                addLightConnection(pixel, c, throughput, bsdfCosine, irradiance, pathLength, pathVelocity, brownian,
                    radiance, sg);
            }
            if (++surfaceDepth >= kMaxBounces) break;
            BSDFSample bsdfSample = {};
            if (!material.sample(surface, sg, bsdfSample, kUseImportanceSampling)) break;
            throughput *= bsdfSample.weight;
            vertex = surface.posW;
            vertexVelocity = velocity;
            vertexIoR = media.ior();
            dir = bsdfSample.wo;
            event = traceThroughMedia(surface.posW, surface.computeRayOrigin(!bsdfSample.isLobe(LobeType::Transmission)),
                dir, media, throughput, sg);
        }
    }
    return radiance / gSamplesPerPixel;
}
#endif

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
#if USE_VOLUMES
    float3 color = tracePathInMedia(pixel, gFrameDim);
#else
    float3 color = tracePath(pixel, gFrameDim);
#endif
#if USE_SINGLE_CHANNEL
    color = float3(selectChannel(color));
#endif
    gOutputColor[pixel] = float4(color, 1.f);
}
