/** Ray and random-number helpers shared by the inline ray tracing passes. USE_ALPHA_TEST is set by the host
    (PathTracingConfig), and is_valid_gViewW by the passes' resource defines.
*/
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.HashUtils;

#ifndef USE_ALPHA_TEST
#define USE_ALPHA_TEST 0
#endif

/// Closest hit along the ray from `origin` in direction `dir`; `hitT` is its distance.
HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
{
    Ray ray = Ray(origin, dir, 0.f, FLT_MAX);
    SceneRayQuery<USE_ALPHA_TEST> sceneRayQuery;
    return sceneRayQuery.traceRay(ray, hitT);
}

/// Direction of the camera's primary ray through `pixel`: from the optional viewW input (`viewW`) when it is
/// connected, otherwise a pinhole ray. The pinhole ray does not follow depth of field; the passes warn about it.
#ifndef is_valid_gViewW
#define is_valid_gViewW 0 // Set by passes that bind the optional viewW input (getValidResourceDefines).
#endif
float3 getPrimaryRayDir(uint2 pixel, uint2 frameDim, Texture2D<float4> viewW)
{
#if is_valid_gViewW
    return -viewW[pixel].xyz;
#else
    return gScene.camera.computeRayPinhole(pixel, frameDim).dir;
#endif
}

/// Ray origin on `surface`, offset to the side that `direction` leaves from (reflection or transmission).
float3 rayOriginToward(ShadingData surface, float3 direction)
{
    return surface.computeRayOrigin(dot(surface.getOrientedFaceNormal(), direction) >= 0.f);
}

// Random streams, so that the sample generators a pass creates for the same pixel and frame do not repeat each other.
// The stream is hashed with the frame count (not added to it): a sum made stream s of frame f equal stream 0 of frame
// f + s, and the spatial reuse seed (a counter) equal the initial pass's reservoir stream.
static const uint kReservoirSampleStream = 0;  ///< ReSTIR: reservoir updates.
static const uint kPathSampleStream = 151;     ///< Camera paths (BSDF sampling, light samples of the path tracers).
static const uint kLightSampleStream = 5713;   ///< ReSTIR: light samples.
static const uint kDirectSampleStream = 7919;  ///< TG ReSTIR: the primary-hit direct term.
static const uint kSpatialReuseStream = 104729; ///< ReSTIR: spatial reuse (seeded with its own counter).
static const uint kTemporalReuseStream = 130363; ///< TH ReSTIR: two-pass temporal reuse.

/// Sample generator for `pixel` in the frame `frameCount`, on random stream `stream`.
SampleGenerator createPixelSampleGenerator(uint2 pixel, uint frameCount, uint stream)
{
    return SampleGenerator(pixel, blockCipherTEA(frameCount, stream).x);
}
