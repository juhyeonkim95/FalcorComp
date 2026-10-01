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
// Ground-truth velocity of the direct path camera -> primary hit (pixel-center ray) -> light; see
// VelocityGroundTruthInline.h for the modes.
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.InstanceVelocity;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
#include "Scene/SceneDefines.slangh"

import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Lights.Laser;

static const uint kModeDoppler = 0;
static const uint kModePathLength = 1;
static const uint kModeProjection = 2;

cbuffer CB
{
    uint2 gFrameDim;
    uint gMode;
    uint gStage;          // path_length: 0 stores l(0), 1 writes the velocity from l(dt).
    float3 gDirection;
    float gDt;
    float3 gSensorVelocity;
    float3 gLightVelocity;
}

StructuredBuffer<InstanceVelocity> gInstanceVelocities;
RWTexture2D<float> gVelocity;
RWTexture2D<float> gFirstLength;

float3 surfaceVelocity(HitInfo hit, float3 posW)
{
    if (!hit.isValid() || hit.getType() != HitType::Triangle) return float3(0.f);
    return gInstanceVelocities[hit.getInstanceID().index].at(posW);
}

// Path-velocity term of the segment from q (the light side) to p (the camera side): (v_q - v_p) . (p - q) / |p - q|.
float segmentVelocity(float3 p, float3 vp, float3 q, float3 vq)
{
    float3 d = p - q;
    float len = length(d);
    return len > 0.f ? dot(vq - vp, d / len) : 0.f;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim)) return;
    Ray cameraRay = gScene.camera.computeRayPinhole(pixel, gFrameDim, false);
    float hitT;
    HitInfo hit = traceRay(cameraRay.origin, cameraRay.dir, hitT);
    if (!hit.isValid())
    {
        gVelocity[pixel] = asfloat(0x7fc00000); // NaN
        return;
    }
    ShadingData surface = loadShadingData(hit, cameraRay.origin, cameraRay.dir);
    // The light endpoint: the point light, or the laser spot (a fixed seed: the same beam direction at both times).
    SampleGenerator sg = SampleGenerator(pixel, 0);
    LaserLightSampler lightSampler = createLaserLightSampler();
    LightSample light = {};
    lightSampler.generateLightSample(sg, light);

    if (gMode == kModeProjection)
    {
        gVelocity[pixel] = dot(surfaceVelocity(hit, surface.posW), gDirection);
        return;
    }
    if (!light.valid)
    {
        gVelocity[pixel] = asfloat(0x7fc00000);
        return;
    }
    if (gMode == kModeDoppler)
    {
        float3 v = surfaceVelocity(hit, surface.posW);
        float u = segmentVelocity(cameraRay.origin, gSensorVelocity, surface.posW, v);
#if IS_LIGHT_SOURCE_LASER
        float3 vSpot = surfaceVelocity(light.hit, light.posW());
        u += segmentVelocity(surface.posW, v, light.posW(), vSpot) +
             segmentVelocity(light.posW(), vSpot, lightSampler.laserOrigin, gLightVelocity);
#else
        u += segmentVelocity(surface.posW, v, light.posW(), gLightVelocity);
#endif
        gVelocity[pixel] = 0.5f * u;
        return;
    }
    // path_length
    float pathLength = hitT + length(light.posW() - surface.posW) + light.laserT;
    if (gStage == 0)
        gFirstLength[pixel] = pathLength;
    else
        gVelocity[pixel] = -(pathLength - gFirstLength[pixel]) / (2.f * gDt);
}
