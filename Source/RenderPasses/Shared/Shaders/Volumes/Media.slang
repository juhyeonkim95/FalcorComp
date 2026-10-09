/** Participating media for the inline path tracers: homogeneous media inside closed triangle meshes (host:
    VolumeConfig).

    A geometry instance is a medium when its material has volume absorption or scattering (BasicMaterial
    volumeAbsorption, volumeScattering, per scene unit, and volumeAnisotropy, a Henyey-Greenstein phase function; 16-bit
    floats, which gMediumProperties replaces in full precision). Its refractive index is the material's IoR. Its surface is a smooth interface between the medium and what surrounds
    it (the enclosing medium, or vacuum with index 1): where the two indices are equal, rays cross it unchanged and
    paths have no vertex there; otherwise it reflects and refracts (Fresnel, Snell), and the crossing is a path vertex.
    Media may be nested (a vessel inside tissue), up to kMaxNestedMedia deep, but must not overlap; their meshes must
    be closed, with outward-facing normals. The camera and the light are outside every medium.

    Light connections from a vertex go straight to the light when every boundary on the way is index-matched, and
    otherwise through one refracting boundary (connectToLightInMedia): the refraction point solves Snell's law on the
    plane of the boundary triangle, and the light arriving there is that of a point source through a planar interface.
    The light is the point light (IS_LIGHT_SOURCE_LASER 0): the host leaves media out with the laser.
*/
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Rendering.Volumes.HomogeneousVolumeSampler;
import Rendering.Volumes.PhaseFunction;
import Utils.Sampling.SampleGenerator;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
import RenderPasses.Shared.Shaders.Utils.PathVelocity;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;

static const uint kMaxNestedMedia = 4;
/// Medium boundaries that a ray may cross between two path vertices (or along a light connection).
static const uint kMaxMediumCrossings = 16;
/// Triangles tried when solving for a refraction point on a faceted boundary.
static const uint kMaxRefractionTriangles = 4;
/// Rays leaving a medium boundary start this fraction (about 128 ulps) of the largest coordinate of the boundary point
/// and of the boundary triangle's vertices away from it, which bounds the error of the hardware's intersection test.
/// (Falcor's computeRayOrigin scales with the point's coordinates alone: too little for a large triangle near the world
/// origin.) Distances in media are measured from the point itself, so no ray offset biases them; geometry closer than
/// the offset to the point is not seen.
static const float kBoundaryOffset = 1.f / 65536.f;

/// Full-precision medium properties of a material (host: VolumeConfig::media): scattering and the Henyey-Greenstein
/// g, absorption and w = 1 where they replace the material's own.
struct MediumOverride
{
    float4 scattering;
    float4 absorption;
};

StructuredBuffer<MediumOverride> gMediumProperties; ///< Per material.

/// Absorption, scattering and phase function of the medium inside the instances made of material `materialID`.
VolumeProperties getMediumProperties(uint materialID)
{
    MediumOverride medium = gMediumProperties[materialID];
    if (medium.absorption.w > 0.f)
        return { medium.absorption.xyz, medium.scattering.xyz, HenyeyGreensteinPhaseFunction(medium.scattering.w) };
    let material = gScene.materials.getMaterial(materialID);
    return material.getHomogeneousVolumeProperties(gScene.materials, materialID);
}

bool isMediumMaterial(uint materialID)
{
    VolumeProperties vp = getMediumProperties(materialID);
    return any(vp.sigmaA > 0.f) || any(vp.sigmaS > 0.f);
}

float getInstanceIoR(uint instance)
{
    return gScene.materials.evalIoR(gScene.getMaterialID(GeometryInstanceID(instance, 0)));
}

/// The media around a point: the geometry instances whose medium contains it, innermost last.
struct MediumStack
{
    uint instances[kMaxNestedMedia];
    uint count;

    bool isEmpty() { return count == 0; }
    uint innermost() { return instances[count - 1]; }

    VolumeProperties properties() { return getMediumProperties(gScene.getMaterialID(GeometryInstanceID(innermost(), 0))); }

    /// Refractive index around the point: the innermost medium's, 1 outside every medium.
    float ior() { return isEmpty() ? 1.f : getInstanceIoR(innermost()); }

    /// Refractive index outside medium `instance`: that of the medium containing it, 1 if none.
    float iorOutside(uint instance)
    {
        float ior = 1.f;
        for (uint i = 0; i < kMaxNestedMedia; ++i)
        {
            if (i >= count || instances[i] == instance) break;
            ior = getInstanceIoR(instances[i]);
        }
        return ior;
    }

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

/// A medium boundary met by a ray: the medium's instance, whether the ray enters it, the boundary triangle's
/// outward face normal, and the refractive indices on the ray's side (n1) and on the other side (n2).
struct MediumBoundary
{
    uint instance;
    bool entering;
    float3 faceNormal;
    float n1;
    float n2;
    float extent; ///< Largest coordinate magnitude of the boundary triangle's vertices.

    bool isIndexMatched() { return abs(n1 - n2) <= 1e-4f * n1; }

    /// Distance from the boundary point `position` at which rays leaving it start (kBoundaryOffset).
    float offset(float3 position)
    {
        float3 a = abs(position);
        return kBoundaryOffset * max(extent, max(a.x, max(a.y, a.z)));
    }

    /// Origin of a ray leaving the boundary point `position` in direction `dir`: offset to the side that `dir` goes to.
    float3 rayOrigin(float3 position, float3 dir)
    {
        float h = offset(position);
        return position + (dot(faceNormal, dir) < 0.f ? -h : h) * faceNormal;
    }
}

/// If `hit` is on the surface of a medium: the boundary that a ray in direction `dir`, inside `media`, meets there.
bool getMediumBoundary(HitInfo hit, float3 dir, MediumStack media, out MediumBoundary boundary)
{
    boundary = {};
    if (hit.getType() != HitType::Triangle) return false;
    TriangleHit triangleHit = hit.getTriangleHit();
    if (!isMediumMaterial(gScene.getMaterialID(triangleHit.instanceID))) return false;
    boundary.instance = triangleHit.instanceID.index;
    boundary.faceNormal = gScene.getFaceNormalW(triangleHit.instanceID, triangleHit.primitiveIndex);
    boundary.entering = dot(boundary.faceNormal, dir) < 0.f;
    float3 p[3];
    gScene.getVertexPositionsW(triangleHit.instanceID, triangleHit.primitiveIndex, p);
    float3 extent = max(abs(p[0]), max(abs(p[1]), abs(p[2])));
    boundary.extent = max(extent.x, max(extent.y, extent.z));
    float inside = getInstanceIoR(boundary.instance);
    boundary.n1 = boundary.entering ? media.ior() : inside;
    boundary.n2 = boundary.entering ? inside : media.iorOutside(boundary.instance);
    return true;
}

/// Unpolarized Fresnel reflectance of a smooth dielectric interface, for the cosine `cosI` of the angle of incidence
/// and the relative index eta = n2 / n1 (n1 on the incident side); 1 for total internal reflection.
float fresnelDielectric(float cosI, float eta)
{
    float sin2T = (1.f - cosI * cosI) / (eta * eta);
    if (sin2T >= 1.f) return 1.f;
    float cosT = sqrt(1.f - sin2T);
    float rs = (cosI - eta * cosT) / (cosI + eta * cosT);
    float rp = (eta * cosI - cosT) / (eta * cosI + cosT);
    return 0.5f * (rs * rs + rp * rp);
}

/// What a camera path ray meets next: a scattering event in a medium, a surface that is not a medium boundary, a
/// refracting medium boundary (Interface), or nothing (the ray leaves the scene, or crosses too many boundaries).
enum class MediumEventType
{
    Scatter,
    Surface,
    Interface,
    Escape,
};

struct MediumEvent
{
    MediumEventType type;
    float3 position;         ///< Scattering position (Scatter), or the interface point (Interface).
    HitInfo hit;             ///< Surface or interface hit.
    float3 origin;           ///< Origin of the ray that met the event, for loading the hit.
    MediumBoundary boundary; ///< The interface (Interface).
}

/// Follows the ray from `start` in direction `dir`, which starts inside `media`, to its next event; `rayOrigin` is
/// `start` offset from the surface or boundary it lies on (`start` itself for a scattering event). Index-matched
/// medium boundaries on the way are crossed (`media` is updated). Inside a medium, a scattering distance from `start`
/// is sampled (HomogeneousVolumeSampler, which samples it by the scattering coefficient); `throughput` takes the
/// transmittance over the distance traveled and the sampling weight.
MediumEvent traceThroughMedia<S : ISampleGenerator>(float3 start, float3 rayOrigin, float3 dir,
    inout MediumStack media, inout float3 throughput, inout S sg)
{
    MediumEvent event = {};
    event.type = MediumEventType::Escape;
    for (uint crossing = 0; crossing <= kMaxMediumCrossings; ++crossing)
    {
        float hitT;
        HitInfo hit = traceRay(rayOrigin, dir, hitT);
        float3 position = rayOrigin + hitT * dir; // The hit, if valid.
        float segment = hit.isValid() ? length(position - start) : FLT_MAX;
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
                    event.position = start + ds.t * dir;
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
        MediumBoundary boundary;
        if (!getMediumBoundary(hit, dir, media, boundary))
        {
            event.type = MediumEventType::Surface;
            event.hit = hit;
            event.origin = rayOrigin;
            return event;
        }
        if (!boundary.isIndexMatched())
        {
            event.type = MediumEventType::Interface;
            event.position = position;
            event.hit = hit;
            event.origin = rayOrigin;
            event.boundary = boundary;
            return event;
        }
        media.cross(boundary.instance, boundary.entering);
        start = position;
        rayOrigin = boundary.rayOrigin(position, dir);
    }
    return event; // Too many boundaries: the path ends.
}

/// A straight segment through media from `start` (inside `media`; `rayOrigin` is `start` offset from the surface or
/// boundary it lies on, if any) towards `endpoint`: its transmittance up to the endpoint, or up to the first refracting
/// medium boundary on the way (refracted, with that boundary and the media just before it). Blocked by any other
/// surface.
struct MediaSegment
{
    bool blocked;
    bool refracted;
    float3 transmittance;
    HitInfo hit;             ///< The refracting boundary (refracted).
    float3 position;         ///< Where the segment meets it (refracted).
    MediumBoundary boundary; ///< That boundary (refracted).
    MediumStack media;       ///< The media around the segment's end (or just before the refracting boundary).
}

MediaSegment marchSegment(float3 start, float3 rayOrigin, MediumStack media, float3 endpoint)
{
    MediaSegment segment = {};
    segment.blocked = true;
    segment.transmittance = float3(1.f);
    for (uint crossing = 0; crossing <= kMaxMediumCrossings; ++crossing)
    {
        float3 toEndpoint = endpoint - rayOrigin;
        float distance = length(toEndpoint);
        if (!(distance > 0.f) || !isfinite(distance))
        {
            segment.blocked = crossing == 0;
            segment.media = media;
            return segment;
        }
        float3 dir = toEndpoint / distance;
        SceneRayQuery<USE_ALPHA_TEST> query;
        float hitT;
        HitInfo hit = query.traceRay(Ray(rayOrigin, dir, 0.f, distance), hitT);
        float3 end = hit.isValid() ? rayOrigin + hitT * dir : endpoint;
        if (!media.isEmpty())
            segment.transmittance *= HomogeneousVolumeSampler::evalTransmittance(media.properties(), length(end - start));
        if (!hit.isValid())
        {
            segment.blocked = false;
            segment.media = media;
            return segment;
        }
        MediumBoundary boundary;
        if (!getMediumBoundary(hit, dir, media, boundary)) return segment; // An opaque surface.
        if (!boundary.isIndexMatched())
        {
            segment.blocked = false;
            segment.refracted = true;
            segment.hit = hit;
            segment.position = end;
            segment.boundary = boundary;
            segment.media = media;
            return segment;
        }
        media.cross(boundary.instance, boundary.entering);
        start = end;
        rayOrigin = boundary.rayOrigin(end, dir);
        // The endpoint may lie within the offset of the boundary.
        if (dot(endpoint - rayOrigin, dir) <= 0.f)
        {
            segment.blocked = false;
            segment.media = media;
            return segment;
        }
    }
    return segment;
}

/// Point y on the plane (p0, normal) where the path from x (index nx) to the light L (index nl), on the other side of
/// the plane, refracts by Snell's law: nl sin(theta_l) = nx sin(theta_x). False when x and L are on the same side.
/// Solved from the foot of the point nearer the plane, which y is near, so that a distant light costs no precision.
bool solveRefractionPoint(float3 x, float3 L, float3 p0, float3 normal, float nx, float nl, out float3 y)
{
    y = float3(0.f);
    float hx = dot(x - p0, normal);
    float hl = dot(L - p0, normal);
    if (!(hx * hl < 0.f)) return false;
    bool fromX = abs(hx) <= abs(hl);
    float3 footNear = fromX ? x - hx * normal : L - hl * normal;
    float3 footFar = fromX ? L - hl * normal : x - hx * normal;
    float hNear = abs(fromX ? hx : hl); // Heights above the plane and indices of the near and far points.
    float hFar = abs(fromX ? hl : hx);
    float nNear = fromX ? nx : nl;
    float nFar = fromX ? nl : nx;
    float3 across = footFar - footNear;
    float rho = length(across);
    if (!(rho > 1e-7f * (hNear + hFar)))
    {
        y = footNear;
        return true;
    }
    // y = footNear + s across / rho, where g(s) = nFar (rho - s) / sqrt((rho - s)^2 + hFar^2) - nNear s /
    // sqrt(s^2 + hNear^2) decreases on [0, rho] from g(0) > 0 to g(rho) < 0: Newton steps where they stay in the
    // bracket, bisection otherwise, from where the straight line crosses the plane.
    float lo = 0.f, hi = rho;
    float s = rho * hNear / (hNear + hFar);
    for (uint i = 0; i < 64; ++i)
    {
        float rest = rho - s;
        float lengthFar = sqrt(rest * rest + hFar * hFar);
        float lengthNear = sqrt(s * s + hNear * hNear);
        float g = nFar * rest / lengthFar - nNear * s / lengthNear;
        if (g > 0.f) lo = s; else hi = s;
        float slope = nFar * hFar * hFar / (lengthFar * lengthFar * lengthFar) +
                      nNear * hNear * hNear / (lengthNear * lengthNear * lengthNear); // -g'(s)
        float next = s + g / slope;
        float previous = s;
        s = (next > lo && next < hi) ? next : 0.5f * (lo + hi);
        if (abs(s - previous) <= 4e-7f * s) break;
    }
    y = footNear + s * (across / rho);
    return true;
}

/// Irradiance, perpendicular to the refracted ray, that a point source of unit intensity, at distance d1 from the
/// refraction point y on a planar interface (angle theta_l to the normal on its side), gives to a point at distance d2
/// from y on the other side (angle theta_x), with n = nx / nl and without Fresnel: the power of the source's cone
/// d omega_l over the area it covers there. At normal incidence it is 1 / (d1 + d2 / n)^2 (the apparent depth), and
/// with n = 1 it is 1 / (d1 + d2)^2.
float refractedIrradianceFactor(float d1, float d2, float cosL, float cosX, float n)
{
    return 1.f / ((d1 + d2 / n) * cosX * (d1 / cosL + d2 * cosL / (n * cosX * cosX)));
}

/// A light connection from a path vertex through media.
struct MediumLightConnection
{
    bool connected;
    bool refracted;
    float3 direction;      ///< At the vertex, towards the light, or towards the refraction point.
    float3 lightDirection; ///< Refracted: from the light towards the refraction point.
    float geometry;        ///< Refracted: refractedIrradianceFactor times the Fresnel transmittance.
    float3 transmittance;  ///< Of the media on the way.
    float length;          ///< Optical length of the connection to the light.
    float pathVelocity;    ///< Path-velocity terms of its segments.

    /// Light arriving at the vertex along `direction`, as irradiance perpendicular to it (zero if not connected).
    /// Evaluated apart from connectToLightInMedia, so that callers keep the order of their random numbers.
    float3 evalIrradiance(LightSample light, float3 position, inout SampleGenerator sg)
    {
        if (!connected) return float3(0.f);
        if (!refracted) return light.evalLi(position, sg) * transmittance;
        return light.evalIntensity(lightDirection, sg) * geometry * transmittance;
    }
}

/// Connects the vertex at `position` (velocity `velocity`, inside `media`; `origin` is its ray origin towards the
/// light) to the point light (velocity `lightVelocity`): straight when every boundary on the way is index-matched, otherwise through the first
/// refracting boundary, at the point y that solves Snell's law on the plane of its triangle (the triangles of the
/// boundary around y are tried in turn). A connection through more than one refracting boundary is blocked. A blocked
/// connection stays `connected` (a valid geometry) with zero transmittance, as checkLightVisibility's callers do.
MediumLightConnection connectToLightInMedia(float3 origin, float3 position, float3 velocity, MediumStack media,
    LightSample light, float3 lightVelocity)
{
    MediumLightConnection c = {};
    if (!light.valid) return c;
    float3 lightPos = light.posW();
    float3 toLight = lightPos - position;
    float distance = length(toLight);
    if (!(distance > 0.f) || !isfinite(distance)) return c;
    float nx = media.ior();
    c.connected = true;
    c.direction = toLight / distance;
    c.transmittance = float3(0.f);
    c.length = nx * distance;
    c.pathVelocity = segmentVelocity(position, velocity, lightPos, lightVelocity, nx);
    // The ray offsets must not reverse a short connection (as checkLightVisibility).
    if (!(dot(lightPos - origin, toLight) > 0.f)) return c;
    MediaSegment straight = marchSegment(position, origin, media, lightPos);
    if (straight.blocked) return c;
    if (!straight.refracted)
    {
        c.transmittance = straight.transmittance;
        return c;
    }

    // Refracted at a boundary between nx (the vertex's side, after index-matched crossings) and nl (the light's).
    float nl = straight.boundary.n2;
    TriangleHit triangle = straight.hit.getTriangleHit();
    float3 y;
    float3 faceNormal;
    MediaSegment inside = {};
    bool found = false;
    for (uint attempt = 0; attempt < kMaxRefractionTriangles && !found; ++attempt)
    {
        float3 p[3];
        gScene.getVertexPositionsW(triangle.instanceID, triangle.primitiveIndex, p);
        faceNormal = gScene.getFaceNormalW(triangle.instanceID, triangle.primitiveIndex);
        if (!solveRefractionPoint(position, lightPos, p[0], faceNormal, nx, nl, y)) return c;
        // y is on the boundary if the segment towards it meets the boundary on y's triangle, or at y (a neighboring
        // triangle in the plane). Otherwise solve again on the triangle that it meets.
        inside = marchSegment(position, origin, media, 2.f * y - position);
        if (inside.blocked || !inside.refracted || inside.boundary.instance != straight.boundary.instance) return c;
        TriangleHit next = inside.hit.getTriangleHit();
        found = next.primitiveIndex == triangle.primitiveIndex ||
                length(inside.position - y) <= 4.f * inside.boundary.offset(y);
        triangle = next;
    }
    if (!found) return c;
    // The light's side: from y to the light, in the media past the boundary.
    float3 toLightFromY = lightPos - y;
    float d1 = length(toLightFromY);
    float3 toVertex = position - y;
    float d2 = length(toVertex);
    if (!(d1 > 0.f) || !(d2 > 0.f)) return c;
    MediumStack outsideMedia = inside.media;
    outsideMedia.cross(inside.boundary.instance, inside.boundary.entering);
    MediaSegment outside = marchSegment(y, inside.boundary.rayOrigin(y, toLightFromY), outsideMedia, lightPos);
    if (outside.blocked || outside.refracted) return c;
    float cosL = abs(dot(faceNormal, toLightFromY)) / d1;
    float cosX = abs(dot(faceNormal, toVertex)) / d2;
    float transmission = 1.f - fresnelDielectric(cosX, nl / nx);
    float3 velocityY = gInstanceVelocities[inside.boundary.instance].at(y);
    c.refracted = true;
    c.direction = -toVertex / d2;
    c.lightDirection = -toLightFromY / d1;
    c.geometry = transmission * refractedIrradianceFactor(d1, d2, cosL, cosX, nx / nl);
    c.transmittance = inside.transmittance * outside.transmittance;
    c.length = nx * d2 + nl * d1;
    c.pathVelocity = segmentVelocity(position, velocity, y, velocityY, nx) +
                     segmentVelocity(y, velocityY, lightPos, lightVelocity, nl);
    return c;
}
