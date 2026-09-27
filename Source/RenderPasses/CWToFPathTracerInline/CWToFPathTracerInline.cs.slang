import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.ShiftMapping.PathLengthAwareShiftmapping;
import RenderPasses.Shared.Shaders.Antithetic.AntitheticMIS;
import RenderPasses.Shared.Shaders.Utils.Waveform;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // Host-bound interface field; dimension offset is not yet consumed.

    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;

    uint samplesPerPixel;
    uint gAntitheticSubsteps;          // ANTITHETIC_MAP_SUBSTEPS: shift steps.
    float gAntitheticGradientThreshold; // ANTITHETIC_MAP_NEWTON: reject pairs with a smaller path-length slope.
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

// Retained for the C++ render-pass bindings; connection sampling traces its own laser ray.
Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const bool kUseAlphaTest = USE_ALPHA_TEST;

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;
static const float kRoundTripTolerance = 0.01f; // Round-trip error allowed, relative to the shift distance.

// ANTITHETIC_MAP: how the antithetic vertex is found.
#define ANTITHETIC_MAP_NEWTON 0   // One Newton solve with the chosen shift mapping (method, gauge).
#define ANTITHETIC_MAP_RADIAL 1   // Along the ray from the path length's minimum on the vertex's plane.
#define ANTITHETIC_MAP_SUBSTEPS 2 // gAntitheticSubsteps Newton solves of dt / gAntitheticSubsteps each.


HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
{
    Ray ray = Ray(origin, dir, 0.0, kRayTMax);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceRay(ray, hitT);
}

/**
 * Returns the primary ray's direction.
 */
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[launchIndex].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
    }
}

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

/// Path length |p1 - X| + |p2 - X| at X, and its derivative along the unit direction u.
float pathLengthAlong(float3 p1, float3 p2, float3 X, float3 u, out float slope)
{
    float3 r1 = p1 - X;
    float3 r2 = p2 - X;
    float d1 = length(r1);
    float d2 = length(r2);
    slope = -dot(u, r1 / d1 + r2 / d2);
    return d1 + d2;
}

/** Radial shift: moves the vertex of `hit` along the ray from m, the minimum of the path length
    |p1 - X| + |p2 - X| on the vertex's plane, until the path length changes by dt. The path length increases
    along every ray from m, so the target has one solution on the ray, and the +dt and -dt shifts are exact
    inverses (the partner lies on the same ray, and m depends only on the plane). The solution must be the
    first hit from p2's vertex on the same plane.
    @param[out] areaJacobian |dA' / dA|, or 0 when there is no partner.
*/
HitInfo radialShift(ShadingData lightEndpoint, HitInfo hit, ShadingData previous, float dt, out float areaJacobian,
    float tolerance)
{
    areaJacobian = 0.f;
    VertexData vertex = gScene.getVertexData(hit.getTriangleHit());
    float3 n = normalize(vertex.faceNormalW);
    float3 x = vertex.posW;
    float3 p1 = lightEndpoint.posW;
    float3 p2 = previous.posW;

    // m: where the segment p1 -> p2 crosses the plane, with p2 mirrored when both are on the same side.
    float h1 = dot(p1 - x, n);
    float h2 = dot(p2 - x, n);
    bool sameSide = h1 * h2 > 0.f;
    float3 q2 = sameSide ? p2 - 2.f * h2 * n : p2;
    float hq2 = sameSide ? -h2 : h2;
    if (!(abs(h1 - hq2) > 1e-12f)) return hit;
    float3 m = p1 + (h1 / (h1 - hq2)) * (q2 - p1);
    m -= dot(m - x, n) * n; // onto the plane

    float3 offset = x - m;
    offset -= dot(offset, n) * n;
    float r = length(offset);
    if (!(r > 1e-6f)) return hit;
    float3 u = offset / r;

    float slopeStart;
    float target = pathLengthAlong(p1, p2, m + r * u, u, slopeStart) + dt;
    if (!(slopeStart > 0.f)) return hit;

    // Bracket the root on the ray, then refine with Newton, falling back to bisection.
    float lo, hi;
    if (dt < 0.f)
    {
        float slopeAtMinimum;
        if (!(target > pathLengthAlong(p1, p2, m, u, slopeAtMinimum))) return hit; // shorter than the minimum
        lo = 0.f;
        hi = r;
    }
    else
    {
        lo = r;
        hi = r + dt;
        float slope;
        uint grow = 0;
        while (pathLengthAlong(p1, p2, m + hi * u, u, slope) < target && grow++ < 40)
            hi = lo + 2.f * (hi - lo);
        if (grow > 40) return hit;
    }
    float s = r;
    float slope = slopeStart;
    bool converged = false;
    for (uint iteration = 0; iteration < 60; iteration++)
    {
        float residual = pathLengthAlong(p1, p2, m + s * u, u, slope) - target;
        if (abs(residual) < tolerance) { converged = true; break; }
        if (residual > 0.f) hi = s; else lo = s;
        float next = slope > 0.f ? s - residual / slope : 0.5f * (lo + hi);
        s = (next > lo && next < hi) ? next : 0.5f * (lo + hi);
    }
    if (!converged || !(slope > 0.f) || !(s > 0.f)) return hit;

    // Polar map (r, angle) -> (s, angle): dA' / dA = (s / r) * (ds / dr), ds / dr = slope(r) / slope(s).
    float3 shiftedPosition = m + s * u;
    HitInfo shifted = trace_shift_endpoint(previous, true, shiftedPosition, tolerance);
    if (!shifted.isValid()) return hit;
    VertexData shiftedVertex = gScene.getVertexData(shifted.getTriangleHit());
    if (!(abs(dot(shiftedVertex.posW - x, n)) <= tolerance && dot(normalize(shiftedVertex.faceNormalW), n) > 0.999999f))
        return hit;
    areaJacobian = (s / r) * (slopeStart / slope);
    return shifted;
}

/// Slope of the path length |p1 - X| + |p2 - X| within the plane of normal n at X.
float tangentialSlope(float3 p1, float3 p2, float3 X, float3 n)
{
    float3 gradient = normalize(p1 - X) + normalize(p2 - X);
    return length(gradient - dot(gradient, n) * n);
}

/// The antithetic vertex for the path-length change dt (ANTITHETIC_MAP). areaJacobian is |dA' / dA|, 0 without one.
HitInfo antitheticShift(ShadingData lightEndpoint, HitInfo hit, ShadingData previous, float dt, out float areaJacobian,
    float tolerance, inout SampleGenerator sg)
{
    ShiftMapDebugInfo debugInfo = {};
#if ANTITHETIC_MAP == ANTITHETIC_MAP_RADIAL
    return radialShift(lightEndpoint, hit, previous, dt, areaJacobian, tolerance);
#elif ANTITHETIC_MAP == ANTITHETIC_MAP_SUBSTEPS
    // Each small step has one solution near its start, so the steps, and their composition, invert exactly.
    uint steps = max(gAntitheticSubsteps, 1u);
    float step = dt / float(steps);
    float stepTolerance = max(abs(step) * gNewtonRelativeTolerance, 1e-6f);
    HitInfo current = hit;
    areaJacobian = 1.f;
    for (uint i = 0; i < steps; i++)
    {
        float stepJacobian = 0.f;
        current = path_length_aware_shift_mapping(lightEndpoint, current, previous, step, stepJacobian, debugInfo,
            stepTolerance, sg);
        if (!(stepJacobian > 0.f) || !isfinite(stepJacobian)) { areaJacobian = 0.f; return hit; }
        areaJacobian *= stepJacobian;
    }
    return current;
#else
    HitInfo shifted = path_length_aware_shift_mapping(lightEndpoint, hit, previous, dt, areaJacobian, debugInfo,
        tolerance, sg);
    if (gAntitheticGradientThreshold > 0.f && areaJacobian > 0.f)
    {
        // Symmetric in the pair: near a minimum of the path length the solve can pick another solution.
        VertexData start = gScene.getVertexData(hit.getTriangleHit());
        VertexData end = gScene.getVertexData(shifted.getTriangleHit());
        float slope = min(tangentialSlope(lightEndpoint.posW, previous.posW, start.posW, normalize(start.faceNormalW)),
            tangentialSlope(lightEndpoint.posW, previous.posW, end.posW, normalize(end.faceNormalW)));
        if (slope < gAntitheticGradientThreshold) areaJacobian = 0.f;
    }
    return shifted;
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
    float tolerance = max(abs(dt) * gNewtonRelativeTolerance, 1e-6f);
    HitInfo shiftedHit = antitheticShift(getLightEndpoint(light), hit, previous, dt, areaJacobian, tolerance, sg);
    if (!(areaJacobian > 0.f) || !isfinite(areaJacobian)) return primalEstimate;
    float3 shiftedPosition = gScene.getVertexData(shiftedHit.getTriangleHit()).posW;

#if ANTITHETIC_ROUND_TRIP_CHECK
    // Keep the shift only if shifting the partner back (-dt) returns to `surface`. Where it is kept, the forward and
    // backward shifts are then exact inverses and one-to-one, as AntitheticMIS needs, even when the Newton solve
    // could land elsewhere (e.g. on another surface with the ray-trace charts).
    float reverseJacobian = 0.f;
    HitInfo returnedHit = antitheticShift(getLightEndpoint(light), shiftedHit, previous, -dt, reverseJacobian,
        tolerance, sg);
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
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 151);

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
