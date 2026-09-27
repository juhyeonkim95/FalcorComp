/** Pinhole projector that shows a signed pattern (ProjectorPatterns), after Mitsuba's projector emitter.
    The host sets the Projector constants (ProjectorConfig).
*/
import RenderPasses.Shared.Shaders.Projector.ProjectorPatterns;

cbuffer Projector
{
    float3 gProjectorPosition;
    float3 gProjectorForward;   // Unit viewing direction.
    float3 gProjectorRight;     // Unit, along +u.
    float3 gProjectorUp;        // Unit, along +v.
    float2 gProjectorTanHalfFov; // tan of the half field of view along u and v.
    float3 gProjectorIntensity;
}

static const float kProjectorNear = 0.01f;
static const float kProjectorFar = 10000.f;

/// Connection of a point to the projector.
struct ProjectorConnection
{
    float3 direction; // Unit, point -> projector.
    float distance;
    float2 uv;        // Projector uv of the point, in [0,1]^2.
    float3 radiance;  // Radiance emitted toward the point, signed by the pattern.
};

struct ProjectorLight
{
    ProjectorPattern pattern;

    float3 position() { return gProjectorPosition; }

    /// Pattern value at uv, in [-1, 1].
    float patternValue(float2 uv) { return gPatternSign * pattern.eval(uv); }

    /// Projector uv of a world-space point; false outside the frustum.
    bool worldToUV(float3 posW, out float2 uv)
    {
        uv = float2(0.f);
        float3 offset = posW - gProjectorPosition;
        float z = dot(offset, gProjectorForward);
        if (z <= kProjectorNear || z >= kProjectorFar) return false;
        float2 imagePlane = float2(dot(offset, gProjectorRight), dot(offset, gProjectorUp)) / z;
        if (any(abs(imagePlane) > gProjectorTanHalfFov)) return false;
        uv = 0.5f * (imagePlane / gProjectorTanHalfFov + 1.f);
        return true;
    }

    /// Unit direction of the projector ray through uv; false outside [0,1]^2.
    bool uvToDirection(float2 uv, out float3 direction)
    {
        direction = float3(0.f);
        if (any(uv < 0.f) || any(uv > 1.f)) return false;
        float2 imagePlane = (2.f * uv - 1.f) * gProjectorTanHalfFov;
        direction = normalize(gProjectorForward + imagePlane.x * gProjectorRight + imagePlane.y * gProjectorUp);
        return true;
    }

    /// Radiance emitted along `direction` through uv. The 1 / cos^3 factor makes the image-plane irradiance
    /// uniform, as for a camera.
    float3 emittedRadiance(float2 uv, float3 direction)
    {
        float cosTheta = dot(direction, gProjectorForward);
        return gProjectorIntensity * patternValue(uv) / (cosTheta * cosTheta * cosTheta);
    }

    /// Solid-angle density of the direction through uv, for uv uniform in [0,1]^2.
    float directionPdf(float3 direction)
    {
        float cosTheta = dot(direction, gProjectorForward);
        float imagePlaneArea = 4.f * gProjectorTanHalfFov.x * gProjectorTanHalfFov.y;
        return 1.f / (imagePlaneArea * cosTheta * cosTheta * cosTheta);
    }

    /// Connection of a world-space point to the projector (without visibility); false outside the frustum.
    bool connect(float3 posW, out ProjectorConnection connection)
    {
        connection = {};
        if (!worldToUV(posW, connection.uv)) return false;
        float3 toProjector = gProjectorPosition - posW;
        connection.distance = length(toProjector);
        connection.direction = toProjector / connection.distance;
        connection.radiance = emittedRadiance(connection.uv, -connection.direction);
        return true;
    }
};
