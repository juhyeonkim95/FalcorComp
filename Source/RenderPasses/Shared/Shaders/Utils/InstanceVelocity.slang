// Instantaneous rigid motion of a geometry instance (Shared/Host/ObjectMotion.h): v(x) = linear + angular x (x - center).
struct InstanceVelocity
{
    float4 linear;
    float4 angular;
    float4 center;

    float3 at(float3 x) { return linear.xyz + cross(angular.xyz, x - center.xyz); }
};
