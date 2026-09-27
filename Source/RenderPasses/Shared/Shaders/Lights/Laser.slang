/** The laser of the frame (Shared/Host/LaserState.h), as published by the LaserLight pass. The host sets the Laser
    constants (LaserState::bindShaderData). IS_LIGHT_SOURCE_LASER picks a laser beam or a point light.
*/
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;

cbuffer Laser
{
    float3 gLaserOrigin;
    float3 gLaserDirection; // Unit beam direction.
    float3 gLaserPower;
    float gLaserCosAngle;   // Cosine of the cone half-angle.
}

/// Light sampler for the laser.
LaserLightSampler createLaserLightSampler()
{
    return LaserLightSampler(gLaserOrigin, gLaserDirection, gLaserCosAngle, gLaserPower);
}
