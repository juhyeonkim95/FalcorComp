/** Participating media for the inline path tracers: homogeneous media inside closed triangle meshes (host:
    VolumeConfig).

    A geometry instance is a medium when its material has volume absorption or scattering (BasicMaterial
    volumeAbsorption, volumeScattering, per scene unit, and volumeAnisotropy, a Henyey-Greenstein phase function).
    Its surface is index-matched: rays cross it unchanged and paths have no vertex there, and inside the medium light
    travels as in vacuum (refractive index 1). Media may be nested (a vessel inside tissue), up to kMaxNestedMedia
    deep, but must not overlap; their meshes must be closed, with outward-facing normals. The camera and the light
    are outside every medium.
*/
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Rendering.Volumes.HomogeneousVolumeSampler;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.RayUtils;

static const uint kMaxNestedMedia = 4;
/// Medium boundaries that a ray may cross between two path vertices (or along a light connection).
static const uint kMaxMediumCrossings = 16;

/// Absorption, scattering and phase function of the medium inside the instances made of material `materialID`.
VolumeProperties getMediumProperties(uint materialID)
{
    let material = gScene.materials.getMaterial(materialID);
    return material.getHomogeneousVolumeProperties(gScene.materials, materialID);
}

bool isMediumMaterial(uint materialID)
{
    VolumeProperties vp = getMediumProperties(materialID);
    return any(vp.sigmaA > 0.f) || any(vp.sigmaS > 0.f);
}

/// The media around a point: the geometry instances whose medium contains it, innermost last.
struct MediumStack
{
    uint instances[kMaxNestedMedia];
    uint count;

    bool isEmpty() { return count == 0; }
    uint innermost() { return instances[count - 1]; }

    VolumeProperties properties() { return getMediumProperties(gScene.getMaterialID(GeometryInstanceID(innermost(), 0))); }

    /// Crossing the surface of medium `instance`: a front face enters it, a back face leaves it. Leaving removes it
    /// wherever it is, so that an unbalanced crossing cannot leave a stale medium on top.
    [mutating]
    void cross(uint instance, bool entering)
    {
        if (entering)
        {
            if (count < kMaxNestedMedia)
                instances[count++] = instance;
            return;
        }
        bool found = false;
        for (uint i = 0; i < kMaxNestedMedia; ++i)
        {
            if (i >= count) break;
            if (!found && instances[i] == instance) found = true;
            if (found && i + 1 < count) instances[i] = instances[i + 1];
        }
        if (found) count--;
    }
}

MediumStack createEmptyMediumStack()
{
    MediumStack media = {};
    media.count = 0;
    return media;
}

/// If `hit` is on the surface of a medium: its instance, and whether a ray in direction `dir` enters it there.
bool getMediumCrossing(HitInfo hit, float3 dir, out uint instance, out bool entering, out float3 faceNormal)
{
    instance = 0;
    entering = false;
    faceNormal = float3(0.f);
    if (hit.getType() != HitType::Triangle) return false;
    TriangleHit triangleHit = hit.getTriangleHit();
    if (!isMediumMaterial(gScene.getMaterialID(triangleHit.instanceID))) return false;
    instance = triangleHit.instanceID.index;
    faceNormal = gScene.getFaceNormalW(triangleHit.instanceID, triangleHit.primitiveIndex);
    entering = dot(faceNormal, dir) < 0.f;
    return true;
}

/// Origin of the ray that continues through a medium boundary at `position`: offset to the side that `dir` goes to.
float3 rayOriginPastBoundary(float3 position, float3 faceNormal, float3 dir)
{
    return computeRayOrigin(position, dot(faceNormal, dir) < 0.f ? -faceNormal : faceNormal);
}

/// What a camera path ray meets next: a scattering event in a medium, a surface that is not a medium boundary, or
/// nothing (the ray leaves the scene, or crosses too many boundaries).
enum class MediumEventType
{
    Scatter,
    Surface,
    Escape,
};

struct MediumEvent
{
    MediumEventType type;
    float3 position; ///< Scattering position (Scatter).
    HitInfo hit;     ///< Surface hit (Surface).
    float3 origin;   ///< Origin of the ray that met the event (after the last boundary crossing), for loading the hit.
}

/// Follows the ray from `origin` in direction `dir`, which starts inside `media`, to its next event. Medium boundaries
/// on the way are crossed (`media` is updated). Inside a medium, a scattering distance is sampled
/// (HomogeneousVolumeSampler, which samples it by the scattering coefficient); `throughput` takes the transmittance
/// over the distance traveled and the sampling weight.
MediumEvent traceThroughMedia<S : ISampleGenerator>(float3 origin, float3 dir, inout MediumStack media,
    inout float3 throughput, inout S sg)
{
    MediumEvent event = {};
    event.type = MediumEventType::Escape;
    float3 rayOrigin = origin;
    for (uint crossing = 0; crossing <= kMaxMediumCrossings; ++crossing)
    {
        float hitT;
        HitInfo hit = traceRay(rayOrigin, dir, hitT);
        float segment = hit.isValid() ? hitT : FLT_MAX;
        if (!media.isEmpty())
        {
            VolumeProperties vp = media.properties();
            HomogeneousVolumeSampler::DistanceSample ds;
            if (HomogeneousVolumeSampler::sampleDistance(vp, throughput, sg, ds))
            {
                if (ds.t < segment)
                {
                    throughput *= ds.evalThroughput(true, 0.f);
                    event.type = MediumEventType::Scatter;
                    event.position = rayOrigin + ds.t * dir;
                    return event;
                }
                throughput *= ds.evalThroughput(false, segment);
            }
            else
            {
                throughput *= HomogeneousVolumeSampler::evalTransmittance(vp, segment);
            }
        }
        if (!hit.isValid()) return event;
        uint instance;
        bool entering;
        float3 faceNormal;
        if (!getMediumCrossing(hit, dir, instance, entering, faceNormal))
        {
            event.type = MediumEventType::Surface;
            event.hit = hit;
            event.origin = rayOrigin;
            return event;
        }
        media.cross(instance, entering);
        rayOrigin = rayOriginPastBoundary(rayOrigin + hitT * dir, faceNormal, dir);
    }
    return event; // Too many boundaries: the path ends.
}

/// Transmittance of the straight connection from `origin` (inside `media`) to `endpoint`: the product of the
/// transmittances of the media it crosses, through their boundaries; zero if any other surface blocks it.
float3 evalConnectionTransmittance(float3 origin, MediumStack media, float3 endpoint)
{
    float3 transmittance = float3(1.f);
    float3 rayOrigin = origin;
    for (uint crossing = 0; crossing <= kMaxMediumCrossings; ++crossing)
    {
        float3 toEndpoint = endpoint - rayOrigin;
        float distance = length(toEndpoint);
        if (!(distance > 0.f) || !isfinite(distance)) return crossing > 0 ? transmittance : float3(0.f);
        float3 dir = toEndpoint / distance;
        SceneRayQuery<USE_ALPHA_TEST> query;
        float hitT;
        HitInfo hit = query.traceRay(Ray(rayOrigin, dir, 0.f, distance), hitT);
        float segment = hit.isValid() ? hitT : distance;
        if (!media.isEmpty())
            transmittance *= HomogeneousVolumeSampler::evalTransmittance(media.properties(), segment);
        if (!hit.isValid()) return transmittance;
        uint instance;
        bool entering;
        float3 faceNormal;
        if (!getMediumCrossing(hit, dir, instance, entering, faceNormal)) return float3(0.f);
        media.cross(instance, entering);
        rayOrigin = rayOriginPastBoundary(rayOrigin + hitT * dir, faceNormal, dir);
        // The endpoint may lie within the offset of the boundary.
        if (dot(endpoint - rayOrigin, dir) <= 0.f) return transmittance;
    }
    return float3(0.f);
}
