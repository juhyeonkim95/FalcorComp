#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

enum ProjectorPatternType
{
    kPatternAll = 0,
    kPatternTrapezoid = 1,
    kPatternTriangle = 2,
    kPatternSinusoidal = 3,
    kPatternExp = 4,
    kPatternGaussian = 5,
    kPatternEPANECHNIKOV = 6,
    kPatternSawtooth = 7
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

    float antitheticCoord1D(float t, float r)
    {
        // t is in one-period coordinate [0, 1)
        float sign = (r > 0.5f) ? -1.0f : 1.0f;

        // return frac(t + sign * 0.5f);
        // float center = 0.5f;
        // return frac(2.0f * center - t);

        if (type != ProjectorPatternType::kPatternSawtooth)
        {
            if(t > 0.25f){
                float t_temp = t - 0.25f;
                float t_mirror = 1 - t_temp;
                return t_mirror + 0.25f;
            } else {
                float t_temp = t + 0.75f;
                float t_mirror = 1 - t_temp;
                return t_mirror - 0.75f;
            }
            
            // float center = (t < 0.5f) ? 0.25f : 0.75f;
            // return frac(2.0f * center - t);
        } else {
            
            // if(t_temp < 0) t_temp += 1.0f;
            // float t_final = t_mirror + 0.25f;
            float center = 0.5f;
            return frac(2.0f * center - t);
        }
    }

    // ============================================================
    // Antithetic UV mapping
    // ============================================================
    float2 antitheticCoord(float2 uv, float r)
    {
        float2 a = getAxis();
        float t = coord(uv);
        float tAnti = antitheticCoord1D(t, r);
        float dt = tAnti - t;
        return uv + dt * wavelength * a;

        // // For most half-wave symmetric patterns:
        // // f(t + 0.5) = -f(t)
        // if (type != ProjectorPatternType::kPatternSawtooth)
        // {
        //     // Project UV to one-period coordinate.
        //     // float s = dot(uv, a);
        //     float t = coord(uv);//frac(s / max(wavelength, 1e-6f));

        //     // Compute antithetic one-period coordinate.
            
        //     // Convert 1D period-coordinate displacement back to UV displacement.
            
        //     // Choose shortest periodic displacement.
        //     // if (dt > 0.5f)  dt -= 1.0f;
        //     // if (dt < -0.5f) dt += 1.0f;
            
        //     // float shift = 0.5f * wavelength;
        //     // float sign = (r < 0.5f) ? -1.0f : 1.0f;
        //     // return uv + sign * shift * a;
        // }

        // // ------------------------------------------------------------
        // // Sawtooth:
        // // f(t) = 2t - 1
        // // Need f(t') = -f(t), so:
        // // 2t' - 1 = -(2t - 1)
        // // t' = 1 - t
        // // ------------------------------------------------------------

        // float wl = max(wavelength, 1e-6f);

        // float t = coord(uv);          // current phase in [0,1)
        // float tp = 1.0f - t;          // opposite sawtooth value

        // // Since phase is periodic, tp = 1 is equivalent to 0.
        // tp = frac(tp);

        // // Phase displacement in cycles.
        // float dt = tp - t;

        // // Choose shortest equivalent displacement.
        // // This keeps the antithetic point close in UV.
        // dt -= round(dt);

        // return uv + dt * wl * a;
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

    float evalBox(float t)
    {
        // Symmetric box centered at 0.5
        // Range: [-1, 1], zero mean

        return (abs(t - 0.5f) < 0.25f) ? 1.0f : -1.0f;
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
        if (type == ProjectorPatternType::kPatternTrapezoid)  return 0.5 * evalBox(t);
        if (type == ProjectorPatternType::kPatternSawtooth)   return evalSawtooth(t);

        return 1.0f;
    }
    float antitheticJacobian(float2 uv){return 1.0;}
};
