// Next-event estimation: connect a surface to a light sample.
// A LightConnection describes only the surface -> light-endpoint segment. Path-level
// quantities (the full path length and its time gate) are computed by the caller:
//     totalLength = pathLength + connection.distance + light.laserT
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;
import RenderPasses.Shared.Lights.LaserLightSampler;

// Offset each surface endpoint toward the open segment. The point-light endpoint
// has no surface to offset. BSDFs and path lengths still use unmodified positions.
bool checkLightVisibility(ShadingData surface, LightSample light)
{
    if (!light.valid) return false;
    float3 segment = light.posW() - surface.posW;
    if (!(dot(segment, segment) > 0.f)) return false;
    float3 origin = surface.computeRayOrigin(dot(surface.getOrientedFaceNormal(), segment) >= 0.f);
    float3 endpoint = light.posW();
#if IS_LIGHT_SOURCE_LASER
    endpoint = light.sd.computeRayOrigin(dot(light.getOrientedFaceNormal(), -segment) >= 0.f);
#endif
    float3 offsetSegment = endpoint - origin;
    if (!(dot(offsetSegment, segment) > 0.f)) return false;
    float distance = length(offsetSegment);
    if (!(distance > 0.f) || !isfinite(distance)) return false;
    SceneRayQuery<USE_ALPHA_TEST> query;
    return query.traceVisibilityRay(Ray(origin, offsetSegment / distance, 0.f, distance));
}

struct LightConnection
{
    float3 direction;        // Unit surface -> light endpoint.
    float distance;          // |light endpoint - surface|; excludes the laser -> endpoint length.
    float3 bsdfCosine;       // BSDF * cosine at the surface for direction.
    float3 incidentRadiance; // Li at the surface from the light sample, zero if occluded.
};

// Invalid or degenerate light samples yield a zero connection.
LightConnection evaluateLightConnection(ShadingData surface, IMaterialInstance material,
    LightSample light, inout SampleGenerator rng)
{
    LightConnection connection = {};
    if (!light.valid) return connection;
    float3 segment = light.posW() - surface.posW;
    connection.distance = length(segment);
    if (!(connection.distance > 0.f) || !isfinite(connection.distance)) return connection;
    connection.direction = segment / connection.distance;
    bool visible = checkLightVisibility(surface, light);
    connection.bsdfCosine = material.eval(surface, connection.direction, rng);
    connection.incidentRadiance = light.evalLi(surface.posW, rng) * float(visible);
    return connection;
}
