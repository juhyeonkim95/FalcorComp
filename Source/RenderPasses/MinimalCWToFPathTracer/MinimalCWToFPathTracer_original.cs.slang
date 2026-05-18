#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Transient.EllipsoidIntersection;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Utils.Transient.Ellipsoid;
import Scene.RaytracingInline;
import GeometricShiftmapping;
import ProjectorLight;
// import ProjectorPatterns.ProjectorPatternInterface;
// import ProjectorPatterns.PeriodicPattern;
// import ProjectorPatterns.XORPattern;
// import ProjectorPatterns.GrayPattern;
// import ProjectorPatterns.OTBitFlipPattern;
// import ProjectorPatterns.ArbitraryAntitheticPattern;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // First available PRNG dimension.
    float specularRoughnessThreshold;

    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
    
    uint samplesPerPixel;

    uint gPatternTotalBits;
    uint gPatternCurrentBit;
    uint gPatternBaseBit;
    bool gPatternUseVertical;

    uint gStratifiedSample;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

EmissiveLightSampler emissiveSampler;           ///< Emissive light sampler. Only valid when kUseEmissiveLights == true.

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const bool kUseAlphaTest = USE_ALPHA_TEST;
static const bool kUseSingleChannel = false;

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;


bool traceVisibilityRay(const float3 origin, const float3 dir, const float distance)
{
    Ray visibilityRay = Ray(origin, dir, 0.0, distance - 1e-3f);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
{
    Ray ray = Ray(origin, dir, 0.0, kRayTMax);
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceRay(ray, hitT);
}


/**
 * Setup ShadingData based on loaded vertex/material attributes for a hit point.
 * @param[in] hit Hit information.
 * @param[in] rayOrigin Ray origin.
 * @param[in] rayDir Normalized ray direction.
 * @return ShadingData struct.
 */
ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir)
{
    VertexData v = {};
    uint materialID = {};

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        v = gScene.getVertexData(triangleHit);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();
        v = gScene.getVertexData(displacedTriangleHit, -rayDir);
        materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit curveHit = hit.getCurveHit();
        v = gScene.getVertexDataFromCurve(curveHit);
        materialID = gScene.getMaterialID(curveHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
    if (hit.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sdfGridHit = hit.getSDFGridHit();
        v = gScene.getVertexDataFromSDFGrid(sdfGridHit, rayOrigin, rayDir);
        materialID = gScene.getMaterialID(sdfGridHit.instanceID);
    }
#endif

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir);
    
    return sd;
}

/**
 * Returns the primary ray's direction.
 */
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[launchIndex].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
    }
}

/** Describes a light sample.
*/
struct LightSample
{
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
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = this.origin - posW;
        float inspot = float(dot(dir, toLight) < 0.0);
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        return Li / distSqr * inspot;
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
    }

    void generateLightSample(
        inout SampleGenerator sg, 
        out LightSample ls
    ) {
        #if IS_LIGHT_SOURCE_LASER
            // (1) Collimated laser 
            float3 local = sample_cone(sampleNext2D(sg), this.laserCosAngle);
            float3 laser_d = normalize(this.laserTangent*local.x + this.laserBitangent*local.y + this.laserDirection*local.z);
            float laserT;
            Ray ray = Ray(this.laserOrigin, laser_d, 0.f, FLT_MAX);
            SceneRayQuery<0> sceneRayQuery;
            ls.hit = sceneRayQuery.traceRay(ray, laserT);
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
        #endif
    }
}

// struct LightSample
// {
//     float3  Li;         ///< Incident radiance at the shading point (unshadowed). This is already divided by the pdf.
//     float distance;
//     float laserT;
//     float3 posW;
//     float3 dir;
// };

// bool generateLightSample(
//     const float3 posW, 
//     inout SampleGenerator sg, 
//     out LightSample ls
// )
// {
// #if IS_LIGHT_SOURCE_LASER
//     // (1) Collimated laser 
//     float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
//     float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
//     float laserT;
//     HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
//     ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
//     let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
//     ls.Li = laserPower * laser_mi.eval(laser_sd, -toLaserHitDir, sg);
//     ls.posW = laser_sd.posW;
//     ls.laserT = laserT;
// #else
//     // (2) Point Light laser 
//     ls.Li = laserPower;
//     ls.posW = laserOrigin;
//     ls.laserT = 0.0;
// #endif
//     // common 
//     float3 toLight = ls.posW - posW;
//     float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
//     ls.Li /= distSqr;
//     ls.distance = sqrt(distSqr);
//     ls.dir = toLight / ls.distance;
// }



/**
 * This is the main entry point for the minimal path tracer.
 *
 * One path per pixel is generated, which is traced into the scene.
 * The path tracer is written as a for-loop over path segments.
 *
 * Built-in light sources (point, directional) are sampled explicitly at each
 * path vertex. The contributions from area lights (env map and mesh lights)
 * are explicitly added by the scatter ray hit/miss shaders.
 *
 * @param[in] pixel Pixel to trace a path for.
 * @param[in] frameDim Dimension of the frame in pixels.
 * @return Returns the estimated color (radiance).
 */
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 151);

        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        BSDFProperties bsdfProperties0 = mi0.getProperties(sd0);
        //
        // Laser Hit Material
        //
        // show laser spot?
        if(kComputeDirect)
        {
            float3 toLaserDir = normalize(laserOrigin - sd0.posW);
            float toLaserDist = length(laserOrigin - sd0.posW);
            bool V = traceVisibilityRay(sd0.computeRayOrigin(), toLaserDir, toLaserDist);
            float minCosAngle = min(laserCosAngle, 1.0-(1e-5));
            bool inspot = (dot(-toLaserDir, laserDirection) > minCosAngle);
            float3 L = mi0.eval(sd0, toLaserDir, sg) * laserPower / (toLaserDist * toLaserDist) * float(inspot);
            L = float3(L.x, 0.0, 0.0);
            outColor += samplesPerPixel * L;
        }
        
        float maxPathLength = getMaxpathLength(tcurr);
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);


        for(uint i=0; i<samplesPerPixel; i++){
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);

            //
            // (1) First Hit Material
            //
            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            BSDFSample bsdfSample;
            float pathLength = length(sd.posW - primaryRayOrigin);

            HitInfo hit = hit0;
            float hitT;
            
            // show direct?
            // if(kComputeDirect){
            //     // sample light
            //     LightSample ls = {};
            //     lls.generateLightSample(sg, ls);
            //     result += throughput * evalDirectConnection(sd, ls, mi, pathLength, sg);
            // }
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid() && pathLength < maxPathLength; depth++){
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;
                
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                pathLength += hitT * sd.IoR;

                if(hit.isValid() && (pathLength < maxPathLength) && any(throughput > 0.)){
                    // update sd, mi
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    // sample light
                    LightSample ls = {};
                    lls.generateLightSample(sg, ls);
                    result += throughput * evalDirectConnection(sd, ls, mi, pathLength, sg);
                }
            }
            if (any(isinf(result) || isnan(result))) result = 0.f;
            outColor += result;
        }
        outColor /= samplesPerPixel;
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    return outColor;
}

float3 evalDirectConnection(
    const ShadingData sd, const LightSample ls, const IMaterialInstance mi,
    float pathLength, inout SampleGenerator sg
)
{
    float3 toLightDir = normalize(ls.posW() - sd.posW);
    float toLightDistance = length(ls.posW() - sd.posW);
    if(toLightDistance < 1e-4){
        return float3(0.0);
    }
    float3 L = mi.eval(sd, toLightDir, sg) * ls.evalLi(sd.posW, sg);
    L *= pathLengthImportance(pathLength + toLightDistance + ls.laserT, tcurr);
    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDistance);
    return L * float(V);
}


[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
#if USE_SINGLE_CHANNEL
    color = float3(color.x, color.x, color.x);
#endif
    gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
}
