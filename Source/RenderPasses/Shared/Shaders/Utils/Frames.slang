/** Small direction helpers for the shared shaders: a unit vector orthogonal to another, and the inverse of the
    area-preserving map from [0,1)^2 to the unit hemisphere.
*/
#include "Utils/Math/MathConstants.slangh"

/// A unit vector orthogonal to the unit vector `normal` (OptiX-style ONB construction).
float3 perp_stark_onb(float3 normal)
{
    float3 binormal;
    if (abs(normal.x) > abs(normal.z))
        binormal = float3(-normal.y, normal.x, 0.f);
    else
        binormal = float3(0.f, -normal.z, normal.y);
    return normalize(binormal);
}

/// Coordinates in [0,1)^2 of a direction on the unit hemisphere (z up) under the area-preserving map
/// (u.x = cos theta, u.y = phi / 2 pi).
float2 inverse_sample_hemisphere_preserve_area(float3 dir)
{
    float u_x = dir.z;
    float phi = atan2(dir.y, dir.x);
    float u_y = phi * M_1_2PI;
    if (u_y < 0.0f) u_y += 1.0f;
    return float2(u_x, u_y);
}
