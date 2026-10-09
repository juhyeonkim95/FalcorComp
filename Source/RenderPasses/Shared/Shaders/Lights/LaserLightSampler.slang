#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Math.MathHelpers;
import RenderPasses.Shared.Shaders.Utils.Frames;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;

#ifndef IS_LIGHT_SOURCE_LASER
#define IS_LIGHT_SOURCE_LASER 0 // Set by the host (LaserState); 0 is the point light.
#endif

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
    float patternPhase;
    /// The fringes' factor in the unit direction `d` from the light: 1 without fringes.
    float pattern(float3 d){
        if (all(patternFrequency == 0.f) && patternPhase == 0.f) return 1.f;
        float along = dot(d, dir);
        return along > 0.f ? 0.5f * (1.f + cos(2.f * M_PI * dot(patternFrequency, d) / along + patternPhase)) : 0.f;
    }
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = this.origin - posW;
        float inspot = float(dot(dir, toLight) < 0.0);
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        float fringes = all(patternFrequency == 0.f) && patternPhase == 0.f ? 1.f : pattern(-toLight / sqrt(distSqr));
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
    float patternPhase;

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
        this.patternPhase = 0.f;
    }

    /// With fringes on the point light.
    __init(float3 laserOrigin, float3 laserDirection, float laserCosAngle, float3 laserPower, float3 patternFrequency,
        float patternPhase){
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