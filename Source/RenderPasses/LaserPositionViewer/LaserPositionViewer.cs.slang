// Adds the laser spot (red channel) to the input image.
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Utils.LoadShadingData;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
    float gSpotScale;
    uint gShowSpot;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float4> gInput; // Optional
RWTexture2D<float4> gOutput;

#define is_valid(name) (is_valid_##name != 0)

float3 getPrimaryRayDir(uint2 pixel)
{
    if (is_valid(gViewW))
        return -gViewW[pixel].xyz;
    return gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;
}

// Light the laser puts on the surface seen in `pixel`, as seen from the camera (not time gated).
float3 laserSpot(uint2 pixel)
{
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (!hit.isValid())
        return float3(0.f);
    ShadingData sd = loadShadingData(hit, gScene.camera.getPosition(), getPrimaryRayDir(pixel));
    let material = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    float3 toLaser = laserOrigin - sd.posW;
    float distanceSq = dot(toLaser, toLaser);
    float3 wi = toLaser / sqrt(distanceSq);
    bool inCone = dot(-wi, laserDirection) > min(laserCosAngle, 1.f - 1e-5f);
    return inCone ? material.eval(sd, wi, sg) * laserPower / distanceSq : float3(0.f);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float4 color = is_valid(gInput) ? gInput[pixel] : float4(0.f, 0.f, 0.f, 1.f);
    if (gShowSpot != 0)
        color.r += gSpotScale * laserSpot(pixel).r;
    gOutput[pixel] = color;
}
