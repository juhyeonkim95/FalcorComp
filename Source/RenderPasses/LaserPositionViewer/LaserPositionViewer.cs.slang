// Adds the laser spot (red) and a marker at the beam's hit point to the input image.
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
    float gMarkerBrightness;
    uint gShowSpot;
    uint gShowMarker;
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

// Continuous pixel position of world point `p` (inverse of Camera::computeRayPinhole). False behind the camera.
bool projectToPixel(float3 p, out float2 position)
{
    let camera = gScene.camera.data;
    float3 d = p - camera.posW;
    float depth = dot(d, camera.cameraW) / dot(camera.cameraW, camera.cameraW);
    position = float2(0.f);
    if (!(depth > 0.f))
        return false;
    float2 ndc = float2(dot(d, camera.cameraU) / dot(camera.cameraU, camera.cameraU),
                        dot(d, camera.cameraV) / dot(camera.cameraV, camera.cameraV)) / depth;
    position = float2(ndc.x + 1.f, 1.f - ndc.y) * 0.5f * float2(gFrameDim);
    return true;
}

// Crosshair around the beam's hit point, with a gap so the point itself stays visible.
bool onMarker(uint2 pixel)
{
    SceneRayQuery<0> query;
    float hitT;
    HitInfo hit = query.traceRay(Ray(laserOrigin, laserDirection, 0.f, FLT_MAX), hitT);
    float2 center;
    if (!hit.isValid() || !projectToPixel(laserOrigin + hitT * laserDirection, center))
        return false;
    int2 d = abs(int2(pixel) - int2(floor(center)));
    return (d.y == 0 && d.x >= 3 && d.x <= 10) || (d.x == 0 && d.y >= 3 && d.y <= 10);
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
    if (gShowMarker != 0 && onMarker(pixel))
        color.rgb = float3(0.f, gMarkerBrightness, gMarkerBrightness);
    gOutput[pixel] = color;
}
