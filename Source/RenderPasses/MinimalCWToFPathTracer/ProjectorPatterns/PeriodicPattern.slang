#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

enum ProjectorPatternType
{
    kPatternSinusoidal = 0,
    kPatternTriangle   = 1,
    kPatternTrapezoid  = 2,
    kPatternSawtooth   = 3,
};

export struct PeriodicPattern : IProjectorPattern
{
    ProjectorPatternType   type;
    float2 axis;        // float2(1,0): vary along u, float2(0,1): vary along v
    float  wavelength;  // UV wavelength, e.g. 0.05
    float  phase;       // cycles, e.g. 0.5 = pi shift
    float  edge;        // trapezoid ramp width, e.g. 0.1

    float2 getAxis()
    {
        return normalize(axis);
    }

    float coord(float2 uv)
    {
        float2 a = getAxis();
        float s = dot(uv, a);
        return frac(s / max(wavelength, 1e-6f) + phase);
    }

    // ============================================================
    // Antithetic UV mapping
    // ============================================================
    float2 antitheticCoord(float2 uv, float r)
    {
        float2 a = getAxis();

        // shift = half wavelength → phase flip (π shift)
        float shift = 0.5f * wavelength;

        // random sign
        float sign = (r < 0.5f) ? -1.0f : 1.0f;

        return uv + sign * shift * a;
    }


    float evalSinusoidal(float t)
    {
        return cos(2.0f * M_PI * t); // [-1,1], zero mean
    }

    float evalTriangle(float t)
    {
        return 1.0f - 4.0f * abs(t - 0.5f); // [-1,1], zero mean
    }

    float evalSawtooth(float t)
    {
        return 2.0f * t - 1.0f; // [-1,1], zero mean
    }

    float evalTrapezoid(float t)
    {
        float e = clamp(edge, 1e-5f, 0.249f);

        // Symmetric trapezoid over one period.
        // Mean is zero. Range is [-1,1].
        if (t < e)
        {
            return -1.0f + 2.0f * t / e;
        }
        else if (t < 0.5f - e)
        {
            return 1.0f;
        }
        else if (t < 0.5f + e)
        {
            return 1.0f - 2.0f * (t - (0.5f - e)) / (2.0f * e);
        }
        else if (t < 1.0f - e)
        {
            return -1.0f;
        }
        else
        {
            return -1.0f + 2.0f * (t - (1.0f - e)) / e;
        }
    }

    float eval(float2 uv)
    {
        float t = coord(uv);

        if (type == ProjectorPatternType::kPatternSinusoidal) return evalSinusoidal(t);
        if (type == ProjectorPatternType::kPatternTriangle)   return evalTriangle(t);
        if (type == ProjectorPatternType::kPatternTrapezoid)  return evalTrapezoid(t);
        if (type == ProjectorPatternType::kPatternSawtooth)   return evalSawtooth(t);

        return 1.0f;
    }
    float antitheticJacobian(float2 uv){return 1.0;}
};
