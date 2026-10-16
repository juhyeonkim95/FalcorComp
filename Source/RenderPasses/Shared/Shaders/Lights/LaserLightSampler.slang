#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Math.MathHelpers;
import RenderPasses.Shared.Shaders.Utils.Frames;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Projector.ProjectorPatterns;

#ifndef IS_LIGHT_SOURCE_LASER
#define IS_LIGHT_SOURCE_LASER 0 // Set by the host (LaserState); 0 is the point light.
#endif

/** The point light as a projector (LaserState::projector, Shared/Host/LaserState.h): a pinhole along the light's
    direction whose image shows the pattern of ProjectorPatterns.slang over its field of view. The host sets these
    constants with the Laser ones.
*/
cbuffer LaserProjector
{
    uint gLaserProjector;             // 1: the point light is a projector.
    float3 gLaserProjectorRight;      // Unit, along +u.
    float3 gLaserProjectorUp;         // Unit, along +v.
    float2 gLaserProjectorTanHalfFov; // tan of the half field of view along u and v.
}

/// Projector uv, in [0,1]^2, of the unit direction `d` from the light whose direction is `forward`; false outside the
/// field of view.
bool laserProjectorUV(float3 d, float3 forward, out float2 uv)
{
    uv = float2(0.f);
    float along = dot(d, forward);
    if (!(along > 0.f)) return false;
    float2 imagePlane = float2(dot(d, gLaserProjectorRight), dot(d, gLaserProjectorUp)) / along;
    if (any(abs(imagePlane) > gLaserProjectorTanHalfFov)) return false;
    uv = 0.5f * (imagePlane / gLaserProjectorTanHalfFov + 1.f);
    return true;
}

/// The projector's factor of the light's intensity in the unit direction `d`: the pattern shown at its uv over cos^3,
/// so that the image-plane irradiance is uniform (as ProjectorLight); zero outside the field of view.
float laserProjectorFactor(float3 d, float3 forward)
{
    float2 uv;
    if (!laserProjectorUV(d, forward, uv)) return 0.f;
    float along = dot(d, forward);
    return shownPatternValue(uv) / (along * along * along);
}

/** Describes a light sample.
*/
struct LightSample
{
    bool valid;
    float laserT;
    HitInfo hit;
    float3 dir;
    float3 Li;
#if IS_LIGHT_SOURCE_LASER
    ShadingData sd;
    IMaterialInstance mi;
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = sd.posW - posW;
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        return Li * mi.eval(sd, normalize(posW - sd.posW), sg) / distSqr;
    }
    float3 getOrientedFaceNormal(){
        return sd.getOrientedFaceNormal();
    }
    float3 posW(){
        return sd.posW;
    }
#else
    float3 origin;
    float3 patternFrequency; ///< Fringes of the point light as a projector (LaserState::patternFrequency).
    float3 patternPhase;     ///< Their phase in each color channel.
    bool hasFringes() { return any(patternFrequency != 0.f) || any(patternPhase != 0.f); }
    bool hasPattern() { return hasFringes() || gLaserProjector != 0; }
    /// The factor of the fringes and of the projector (laserProjectorFactor) in the unit direction `d` from the light,
    /// per color channel: 1 without them.
    float3 pattern(float3 d){
        float3 factor = float3(1.f);
        if (hasFringes())
        {
            float along = dot(d, dir);
            factor = along > 0.f ? 0.5f * (1.f + cos(2.f * M_PI * dot(patternFrequency, d) / along + patternPhase)) : 0.f;
        }
        if (gLaserProjector != 0) factor *= laserProjectorFactor(d, dir);
        return factor;
    }
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = this.origin - posW;
        float inspot = float(dot(dir, toLight) < 0.0);
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        float3 fringes = hasPattern() ? pattern(-toLight / sqrt(distSqr)) : float3(1.f);
        return Li / distSqr * inspot * fringes;
    }
    // Radiant intensity leaving the light in direction `d` (from the light): evalLi times the squared distance.
    float3 evalIntensity(float3 d, inout SampleGenerator sg){
        return Li * float(dot(dir, d) > 0.0) * pattern(d);
    }
    float3 getOrientedFaceNormal(){
        return dir;
    }
    float3 posW(){
        return origin;
    }
#endif
}

// Laser Sampling
struct LaserLightSampler
{
    float3 laserOrigin;
    float3 laserDirection;
    float laserCosAngle;
    float3 laserPower;

    float3 patternFrequency; ///< Fringes of the point light (LaserState::patternFrequency).
    float3 patternPhase;     ///< Per color channel.

    // helper axis
    float3 laserTangent;
    float3 laserBitangent;
    
    
    __init(float3 laserOrigin, float3 laserDirection, float laserCosAngle, float3 laserPower){
        this.laserOrigin = laserOrigin;
        this.laserDirection = laserDirection;
        this.laserCosAngle = laserCosAngle;
        this.laserBitangent = perp_stark_onb(laserDirection);
        this.laserTangent = cross(laserBitangent, laserDirection);
        this.laserPower = laserPower;
        this.patternFrequency = float3(0.f);
        this.patternPhase = float3(0.f);
    }

    /// With fringes on the point light.
    __init(float3 laserOrigin, float3 laserDirection, float laserCosAngle, float3 laserPower, float3 patternFrequency,
        float3 patternPhase){
        this.laserOrigin = laserOrigin;
        this.laserDirection = laserDirection;
        this.laserCosAngle = laserCosAngle;
        this.laserBitangent = perp_stark_onb(laserDirection);
        this.laserTangent = cross(laserBitangent, laserDirection);
        this.laserPower = laserPower;
        this.patternFrequency = patternFrequency;
        this.patternPhase = patternPhase;
    }

    void generateLightSample(
        inout SampleGenerator sg, 
        out LightSample ls
    ) {
        ls = {};
        #if IS_LIGHT_SOURCE_LASER
            // (1) Collimated laser 
            float3 local = sample_cone(sampleNext2D(sg), this.laserCosAngle);
            float3 laser_d = normalize(this.laserTangent*local.x + this.laserBitangent*local.y + this.laserDirection*local.z);
            float laserT;
            Ray ray = Ray(this.laserOrigin, laser_d, 0.f, FLT_MAX);
            SceneRayQuery<USE_ALPHA_TEST> sceneRayQuery;
            ls.hit = sceneRayQuery.traceRay(ray, laserT);
            if (!ls.hit.isValid()) return;
            ls.dir = laser_d;
            ls.sd = loadShadingData(ls.hit, this.laserOrigin, laser_d);
            ls.mi = gScene.materials.getMaterialInstance(ls.sd, ExplicitLodTextureSampler(0.f));
            ls.laserT = laserT;
            ls.Li = laserPower;
        #else
            // (2) Point Light laser
            ls.hit = makeInvalidHit(); // dummy hit
            ls.dir = this.laserDirection; // dummy direction
            ls.laserT = 0.0;
            ls.origin = this.laserOrigin;
            ls.Li = laserPower;
            ls.patternFrequency = this.patternFrequency;
            ls.patternPhase = this.patternPhase;
        #endif
        ls.valid = true;
    }
}