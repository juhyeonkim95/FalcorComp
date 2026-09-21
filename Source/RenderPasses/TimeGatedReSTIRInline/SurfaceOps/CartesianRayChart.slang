// Cartesian slopes in a FIXED orthonormal frame: d = normalize(n + u*t + v*b).
// The chart is regular at u=v=0 and has no azimuth seam. Its boundary is the
// frame's horizon, which must not be crossed or clamped during Newton iteration.
export struct CartesianRayChart
{
    static bool isValid(float2 coordinates)
    {
        float s2 = 1.f + dot(coordinates, coordinates);
        return all(isfinite(coordinates)) && isfinite(s2) && s2 < 1e12f;
    }

    static float3 direction(float2 coordinates)
    {
        return float3(coordinates, 1.f) * rsqrt(1.f + dot(coordinates, coordinates));
    }

    // dOmega / (du dv). Unlike the polar equal-area chart, this is not constant.
    static float solidAngleDensity(float2 coordinates)
    {
        float invS = rsqrt(1.f + dot(coordinates, coordinates));
        return invS * invS * invS;
    }

    static void derivatives(float2 coordinates,
        out float3 d, out float3 du, out float3 dv,
        out float3 duu, out float3 duv, out float3 dvv)
    {
        float u = coordinates.x, v = coordinates.y;
        float3 w = float3(coordinates, 1.f);
        float3 t = float3(1.f, 0.f, 0.f), b = float3(0.f, 1.f, 0.f);
        float invS = rsqrt(1.f + dot(coordinates, coordinates));
        float invS3 = invS * invS * invS;
        float invS5 = invS3 * invS * invS;
        d = w * invS;
        du = t * invS - w * u * invS3;
        dv = b * invS - w * v * invS3;
        duu = -(2.f * u * t + w) * invS3 + 3.f * w * u * u * invS5;
        duv = -(v * t + u * b) * invS3 + 3.f * w * u * v * invS5;
        dvv = -(2.f * v * b + w) * invS3 + 3.f * w * v * v * invS5;
    }
};
