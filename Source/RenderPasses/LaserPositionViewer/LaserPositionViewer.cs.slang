// Draws the laser spot and the laser's cone over the input image, or outputs them as an overlay.
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
    float3 gSpotColor;
    float gSpotScale;
    float3 gConeColor;
    float gConeDensity;
    float gBeamRadius;
    uint gShowSpot;
    uint gShowCone;
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

// Length of the part of [lo, hi] where the quadratic a t^2 + b t + c is <= 0.
float lengthWhereNonPositive(float a, float b, float c, float lo, float hi)
{
    if (!(hi > lo))
        return 0.f;
    // Split [lo, hi] at the real roots and test the middle of each piece.
    float roots[2] = { lo, lo };
    if (abs(a) > 1e-12f)
    {
        float discriminant = b * b - 4.f * a * c;
        if (discriminant >= 0.f)
        {
            float s = sqrt(discriminant);
            roots[0] = (-b - s) / (2.f * a);
            roots[1] = (-b + s) / (2.f * a);
        }
    }
    else if (abs(b) > 1e-12f)
    {
        roots[0] = roots[1] = -c / b;
    }
    float points[4] = { lo, clamp(min(roots[0], roots[1]), lo, hi), clamp(max(roots[0], roots[1]), lo, hi), hi };
    float inside = 0.f;
    for (uint i = 0; i < 3; ++i)
    {
        float t = 0.5f * (points[i] + points[i + 1]);
        if ((a * t + b) * t + c <= 0.f)
            inside += points[i + 1] - points[i];
    }
    return inside;
}

// Distance the camera ray of `pixel` travels inside the laser's cone before it hits the scene. The cone starts at
// the laser with radius gBeamRadius, widens at the cone angle, and ends where the central beam hits the scene.
float lengthInCone(uint2 pixel)
{
    float3 origin = gScene.camera.getPosition();
    float3 dir = normalize(getPrimaryRayDir(pixel));
    HitInfo hit = HitInfo(gVBuffer[pixel]);
    float tSurface = hit.isValid() ? length(loadShadingData(hit, origin, dir).posW - origin) : FLT_MAX;

    SceneRayQuery<0> query;
    float beamLength;
    if (!query.traceRay(Ray(laserOrigin, laserDirection, 0.f, FLT_MAX), beamLength).isValid())
        return 0.f;

    // Points p with |p - apex - z d|^2 <= (r0 + k z)^2 and 0 <= z <= beamLength, z = dot(p - apex, d).
    float cosAngle = clamp(laserCosAngle, 0.f, 1.f);
    float k = sqrt(max(1.f - cosAngle * cosAngle, 0.f)) / max(cosAngle, 1e-6f); // tan of the half-angle
    float3 w = origin - laserOrigin;
    float z0 = dot(w, laserDirection);
    float dz = dot(dir, laserDirection);
    float3 wPerp = w - z0 * laserDirection;
    float3 dirPerp = dir - dz * laserDirection;
    float c0 = gBeamRadius + k * z0;
    float c1 = k * dz;
    float a = dot(dirPerp, dirPerp) - c1 * c1;
    float b = 2.f * (dot(wPerp, dirPerp) - c0 * c1);
    float c = dot(wPerp, wPerp) - c0 * c0;

    // Ray parameters where 0 <= z <= beamLength.
    float lo = 0.f;
    float hi = tSurface;
    if (abs(dz) > 1e-8f)
    {
        float t0 = -z0 / dz;
        float t1 = (beamLength - z0) / dz;
        lo = max(lo, min(t0, t1));
        hi = min(hi, max(t0, t1));
    }
    else if (z0 < 0.f || z0 > beamLength)
    {
        return 0.f;
    }
    return lengthWhereNonPositive(a, b, c, lo, hi);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    // Overlay with premultiplied alpha: an image under it becomes image * (1 - alpha) + overlay.rgb.
    float4 overlay = float4(0.f);
    if (gShowSpot != 0)
    {
        float3 spot = laserSpot(pixel);
        overlay.rgb += gSpotScale * (spot.r + spot.g + spot.b) / 3.f * gSpotColor;
    }
    if (gShowCone != 0)
    {
        float opacity = 1.f - exp(-gConeDensity * lengthInCone(pixel));
        overlay = float4(overlay.rgb * (1.f - opacity) + gConeColor * opacity, opacity);
    }

    if (is_valid(gInput))
    {
        float4 color = gInput[pixel];
        gOutput[pixel] = float4(color.rgb * (1.f - overlay.a) + overlay.rgb, color.a);
    }
    else
    {
        gOutput[pixel] = overlay;
    }
}
