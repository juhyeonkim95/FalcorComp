#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatterns.ProjectorPatternInterface;

// enum ProjectorPatternType
// {
//     kPatternSinusoidal = 0,
//     kPatternTriangle   = 1,
//     kPatternTrapezoid  = 2,
//     kPatternSawtooth   = 3,
// };

// struct ProjectorPattern
// {
//     ProjectorPatternType   type;
//     float2 axis;        // float2(1,0): vary along u, float2(0,1): vary along v
//     float  wavelength;  // UV wavelength, e.g. 0.05
//     float  phase;       // cycles, e.g. 0.5 = pi shift
//     float  edge;        // trapezoid ramp width, e.g. 0.1

//     float2 getAxis()
//     {
//         return normalize(axis);
//     }

//     float coord(float2 uv)
//     {
//         float2 a = getAxis();
//         float s = dot(uv, a);
//         return frac(s / max(wavelength, 1e-6f) + phase);
//     }

//     // ============================================================
//     // Antithetic UV mapping
//     // ============================================================
//     float2 antitheticCoord(float2 uv, float r)
//     {
//         float2 a = getAxis();

//         // shift = half wavelength → phase flip (π shift)
//         float shift = 0.5f * wavelength;

//         // random sign
//         float sign = (r < 0.5f) ? -1.0f : 1.0f;

//         return uv + sign * shift * a;
//     }


//     float evalSinusoidal(float t)
//     {
//         return cos(2.0f * M_PI * t); // [-1,1], zero mean
//     }

//     float evalTriangle(float t)
//     {
//         return 1.0f - 4.0f * abs(t - 0.5f); // [-1,1], zero mean
//     }

//     float evalSawtooth(float t)
//     {
//         return 2.0f * t - 1.0f; // [-1,1], zero mean
//     }

//     float evalTrapezoid(float t)
//     {
//         float e = clamp(edge, 1e-5f, 0.249f);

//         // Symmetric trapezoid over one period.
//         // Mean is zero. Range is [-1,1].
//         if (t < e)
//         {
//             return -1.0f + 2.0f * t / e;
//         }
//         else if (t < 0.5f - e)
//         {
//             return 1.0f;
//         }
//         else if (t < 0.5f + e)
//         {
//             return 1.0f - 2.0f * (t - (0.5f - e)) / (2.0f * e);
//         }
//         else if (t < 1.0f - e)
//         {
//             return -1.0f;
//         }
//         else
//         {
//             return -1.0f + 2.0f * (t - (1.0f - e)) / e;
//         }
//     }

//     float eval(float2 uv)
//     {
//         float t = coord(uv);

//         if (type == ProjectorPatternType::kPatternSinusoidal) return evalSinusoidal(t);
//         if (type == ProjectorPatternType::kPatternTriangle)   return evalTriangle(t);
//         if (type == ProjectorPatternType::kPatternTrapezoid)  return evalTrapezoid(t);
//         if (type == ProjectorPatternType::kPatternSawtooth)   return evalSawtooth(t);

//         return 1.0f;
//     }
// };


struct ProjectorLight
{
    float3 positionW;      // projector center in world space
    float3 dirW;           // forward direction (unit)
    float3 rightW;         // local +x (unit)
    float3 upW;            // local +y (unit)

    float  tanHalfFovX;    // tan(fovX * 0.5)
    float  tanHalfFovY;    // tan(fovY * 0.5)

    float3 intensity;      // RGB scale
    float  nearZ;          // optional, usually small > 0
    float  farZ;           // optional, set large if not needed

    IProjectorPattern pattern;
};

struct ProjectorSample
{
    bool   valid;
    float3 wi;             // direction from shading point toward projector
    float  distance;       // distance to projector center
    float3 radiance;       // emitted radiance along this direction
    float  pdf;            // if sampled deterministically, keep as 1
    float2 uv;             // projector uv in [0,1]^2, useful later for patterns
};

// Evaluate projected light contribution toward a shading point xW.
// This does NOT do visibility/shadow ray. Do that outside.
// `pattern = 1` for now.
ProjectorSample evalProjectorLight(ProjectorLight light, float3 xW)
{
    ProjectorSample s;
    s.valid    = false;
    s.wi       = 0.f;
    s.distance = 0.f;
    s.radiance = 0.f;
    s.pdf      = 0.f;
    s.uv       = 0.f;

    // Vector from projector to shading point.
    float3 d = xW - light.positionW;

    // Coordinates in projector local frame.
    float x = dot(d, light.rightW);
    float y = dot(d, light.upW);
    float z = dot(d, light.dirW);

    // Must be in front of projector.
    if (z <= light.nearZ || z >= light.farZ) return s;

    // Perspective projection onto virtual image plane at z = 1.
    float px = x / z;
    float py = y / z;

    // Rectangular frustum test.
    if (abs(px) > light.tanHalfFovX) return s;
    if (abs(py) > light.tanHalfFovY) return s;

    // Map to [0,1]^2 for future texture lookup.
    float u = 0.5f * (px / light.tanHalfFovX + 1.f);
    float v = 0.5f * (py / light.tanHalfFovY + 1.f);
    s.uv = float2(u, v);

    // Direction from shading point toward projector.
    float3 toLight = light.positionW - xW;
    float  dist2   = dot(toLight, toLight);
    float  dist    = sqrt(dist2);
    float3 wi      = toLight / dist;

    // cos(theta) at projector, where theta is angle from projector forward axis
    // toward the point.
    //
    // Since d points projector -> point, normalize(d) is emission direction.
    float cosTheta = z / length(d);
    if (cosTheta <= 0.f) return s;

    // Pattern is constant = 1 for now.
    float pattern = light.pattern.eval(s.uv);

    // Important:
    // For a perspective/projector emitter, emitted radiance should include
    // the reciprocal camera importance correction. For a constant image-plane
    // irradiance, this gives a 1 / cos^3(theta) factor.
    //
    // This matches the Mitsuba projector description.
    float projectorScale = 1.f / (cosTheta * cosTheta * cosTheta);

    s.valid    = true;
    s.wi       = wi;
    s.distance = dist;
    s.radiance = light.intensity * pattern * projectorScale;
    s.pdf      = 1.f; // deterministic evaluation, not stochastic light sampling

    return s;
}

// Convert a world-space point to projector UV.
// Returns false if the point is outside the projector frustum.
bool worldToProjectorUV(const ProjectorLight light, float3 xW, out float2 uv)
{
    float3 d = xW - light.positionW;

    float x = dot(d, light.rightW);
    float y = dot(d, light.upW);
    float z = dot(d, light.dirW);

    uv = 0.0;

    if (z <= light.nearZ || z >= light.farZ) return false;

    float px = x / z;
    float py = y / z;

    if (abs(px) > light.tanHalfFovX) return false;
    if (abs(py) > light.tanHalfFovY) return false;

    float u = 0.5f * (px / light.tanHalfFovX + 1.f);
    float v = 0.5f * (py / light.tanHalfFovY + 1.f);
    uv = float2(u, v);

    return true;
}

// Convert projector UV in [0,1]^2 to a world-space ray direction
// leaving the projector center.
bool projectorUVToWorldRay(const ProjectorLight light, float2 uv, out float3 rayDirW)
{
    rayDirW = 0.0;

    // Reject out-of-range UV.
    if (any(uv < 0.0) || any(uv > 1.0)) return false;

    // Back to projector local image-plane coordinates.
    float px = (2.f * uv.x - 1.f) * light.tanHalfFovX;
    float py = (2.f * uv.y - 1.f) * light.tanHalfFovY;

    // Ray through image plane z = 1 in local projector frame.
    float3 dirLocal = normalize(float3(px, py, 1.f));

    // Local -> world using projector basis.
    rayDirW = normalize(
        dirLocal.x * light.rightW +
        dirLocal.y * light.upW +
        dirLocal.z * light.dirW
    );

    return true;
}