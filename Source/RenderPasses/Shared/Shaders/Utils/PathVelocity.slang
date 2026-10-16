/** Path velocity u(x) (OHD path integral, Kim et al. 2025, Eq. 32): the sum, over the segments of a path, of the
    velocities of their endpoints along the segment, from the instantaneous motions of the geometry instances
    (gInstanceVelocities; host: createInstanceVelocityBuffer in Shared/Host/ObjectMotion.h).
*/
import Scene.HitInfo;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;

// Instantaneous motion of a geometry instance: v(x) = linear + angular x (x - center), plus a Poiseuille flow,
// maxSpeed (1 - r^2 / R^2) along the axis within R of it. Its medium's scatterers also diffuse (Brownian motion).
struct InstanceVelocity
{
    float4 linear;
    float4 angular;
    float4 center;
    float4 flowOrigin; ///< xyz: a point on the flow's axis; w: the flow's radius R.
    float4 flowAxis;   ///< xyz: the axis' unit direction; w: the speed on the axis (0: no flow).
    float4 diffusion;  ///< x: Brownian diffusion coefficient of the scatterers (m^2/s).

    float3 at(float3 x)
    {
        float3 v = linear.xyz + cross(angular.xyz, x - center.xyz);
        if (flowAxis.w != 0.f)
        {
            float3 offset = x - flowOrigin.xyz;
            float3 radial = offset - dot(offset, flowAxis.xyz) * flowAxis.xyz;
            v += flowAxis.w * max(0.f, 1.f - dot(radial, radial) / (flowOrigin.w * flowOrigin.w)) * flowAxis.xyz;
        }
        return v;
    }
};

StructuredBuffer<InstanceVelocity> gInstanceVelocities;

// Velocity of the scene surface point posW, hit by `hit`.
float3 surfaceVelocity(HitInfo hit, float3 posW)
{
    if (!hit.isValid() || hit.getType() != HitType::Triangle) return float3(0.f);
    return gInstanceVelocities[hit.getInstanceID().index].at(posW);
}

// Path-velocity term of the segment between q (the light side) and p (the camera side), with refractive index eta:
// eta (v_q - v_p) . (p - q) / |p - q|.
float segmentVelocity(float3 p, float3 vp, float3 q, float3 vq, float eta = 1.f)
{
    float3 d = p - q;
    float len = length(d);
    return len > 0.f ? eta * dot(vq - vp, d / len) : 0.f;
}

// Path-velocity terms of the connection from surface point s (velocity vs) to the light: to the laser spot and on to
// the laser origin, or to the point light. The light moves at lightVelocity.
float connectionVelocity(float3 s, float3 vs, LightSample light, float3 lightOrigin, float3 lightVelocity)
{
#if IS_LIGHT_SOURCE_LASER
    float3 spot = light.posW();
    float3 vSpot = surfaceVelocity(light.hit, spot);
    return segmentVelocity(s, vs, spot, vSpot) + segmentVelocity(spot, vSpot, lightOrigin, lightVelocity);
#else
    return segmentVelocity(s, vs, light.posW(), lightVelocity);
#endif
}
