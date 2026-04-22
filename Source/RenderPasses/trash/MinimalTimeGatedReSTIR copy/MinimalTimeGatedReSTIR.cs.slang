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
import Reservoirs;
import LoadShadingData;
import TransientShiftmapping;


cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // First available PRNG dimension.

    uint samplesPerPixel;
    uint2 gLaserHitVBufferRes;

}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Laser V Buffer (1 pixel)
Texture2D<PackedHitInfo> gLaserVBuffer;
Texture2D<float4> gLaserViewW;

// Laser Hit V Buffer (256 x 256)
Texture2D<PackedHitInfo> gLaserHitVBuffer;
Texture2D<float4> gLaserHitViewW;
Texture2D<float> gLaserHitDepth;

// Reservoir Struct
StructuredBuffer<Reservoir> prevReservoirs;
RWStructuredBuffer<Reservoir> currReservoirs;

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
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;


bool traceVisibilityRay(const float3 origin, const float3 dir, const float distance)
{
    Ray visibilityRay = Ray(origin, dir, 0.f, distance - 0.001f);
    SceneRayQuery<0> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

HitInfo traceRay(const float3 origin, const float3 dir, out float hitT)
{
    Ray ray = Ray(origin, dir, 0.f, kRayTMax);
    SceneRayQuery<0> sceneRayQuery;
    return sceneRayQuery.traceRay(ray, hitT);
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
    const uint linearizedPixel = pixel.y * frameDim.x + pixel.x;
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);

        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        float d01 = length(sd0.posW - primaryRayOrigin);

        //
        // Laser Hit Material
        //
        const HitInfo laserhit = HitInfo(gLaserVBuffer[uint2(0,0)]);
        const float4 laserViewW = gLaserViewW[uint2(0,0)];
        const float laserT = laserViewW.w;
        ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laserDirection);
        float3 laser_sd_n = laser_sd.getOrientedFaceNormal();
        let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
        
        LightSample lightSampleLaser;
        lightSampleLaser.p = laser_sd.posW;
        lightSampleLaser.n = laser_sd_n;
        lightSampleLaser.hit = laserhit;

        Reservoir reservoir = Reservoir();

        LightSample lightSample;
        LightSample lightSample2;
        float3 direction;

        uint M = samplesPerPixel;

        uint M_brdf = M;

        float maxPathLength = getMaxpathLength(tcurr);

        for(uint i=0; i<M_brdf; i++){
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);
            float3 prefixThroughput = float3(1.0f);
            float postfixPathLength = 0.0;

            //
            // (1) First Hit Material
            //
            mi0.sample(sd0, sg, bsdfSample, kUseImportanceSampling);
            throughput *= bsdfSample.weight;
                
            hit = traceRay(sd.computeRayOrigin(), bsdfSample.wo, hitT);

            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            BSDFSample bsdfSample;
            float pathLength = length(sd.posW - primaryRayOrigin);

            HitInfo hit = hit0;
            float hitT;
            
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++){
                // -------------------- BSDF Sampling ----------------------
                mi.sample(sd, sg, bsdfSample, kUseImportanceSampling);
                throughput *= bsdfSample.weight;
                
                hit = traceRay(sd.computeRayOrigin(), bsdfSample.wo, hitT);
                if(hit.isValid()){
                    pathLength += hitT;
                    sd = loadShadingData(hit, sd.computeRayOrigin(), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    if(depth == 1){
                        lightSample.p = sd.posW;
                        lightSample.hit = hit;
                        lightSample.n = sd.getOrientedFaceNormal();
                        // lightSample2 = lightSampleLaser
                        // radiance = laserPower;
                        direction = laserDirection;
                    }
                    else if(depth == 2){
                        lightSample2.p = sd.posW;
                        lightSample2.hit = hit;
                        lightSample2.n = sd.getOrientedFaceNormal();
                        radiance = L_laser;
                        direction = laserDirection;
                    }
                    else if(depth == 3){
                        direction = normalize(laser_sd.posW - sd.posW);
                        prefixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    } else {
                        prefixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    }

                    // float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
                    // float toLaserHitDist = length(laser_sd.posW - sd.posW);
                    // bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
                    // float3 L_laser = laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower;
                    // float3 L = mi.eval(sd, toLaserHitDir, sg) * L_laser;
                    // L *= pathLengthImportance(pathLength + toLaserHitDist, tcurr);
                    // return L * V;

                    float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
                    float toLaserHitDist = length(laser_sd.posW - sd.posW);
                    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
                    float3 L_mi = mi.eval(sd, toLaserHitDir, sg);
                    float3 L_laser_mi = laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower;
                    float pathLengthWeight = pathLengthImportance(pathLength + toLaserHitDist + laserT, tcurr);

                    // float3 laserf = evalDirectConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, sg);

                    float3 f = throughput * L_mi * L_laser_mi * pathLengthWeight;
                    flaot3 prefixf = prefixThroughput * L_laser_mi * max(0.0, dot(sd.getOrientedFaceNormal(), toLaserHitDir));
                    
                    f = float3(f.x);
                    float weight = luminance(f) * 1.0 / M;
                    if(reservoir.update(f, weight, sg))
                    {
                        reservoir.lightSample = lightSample;
                        reservoir.lightSample2 = (depth == 1) ? lightSampleLaser : lightSample2;
                        reservoir.direction = (depth == 1) ? laserDirection : direction;
                        reservoir.radiance = (depth == 1) ? laserPower : prefixf;
                        reservoir.postfixPathLength = (depth == 1) ? laserT : postfixPathLength + toLaserHitDist + laserT;
                    }
                }
            }
        }


        float pHat = luminance(reservoir.f);
        reservoir.W = pHat > 0 ? 1.0f / pHat * reservoir.wSum : 0.0;

        // have any valid sample --> check visibility
        // if(reservoir.W > 0.0){
        //     bool V1 = traceVisibilityRay(laser_sd.computeRayOrigin(), 
        //         normalize(reservoir.lightSample.p - laser_sd.posW), length(reservoir.lightSample.p - laser_sd.posW));
        //     reservoir.W *= float(V1);
            
        //     // bool V2 = traceVisibilityRay(sd0.computeRayOrigin(), 
        //     //     normalize(reservoir.lightSample.p - sd0.posW), length(reservoir.lightSample.p - sd0.posW));
        //     // reservoir.W *= float(V2);
        // }
        outColor = reservoir.W * reservoir.f;
        currReservoirs[linearizedPixel] = reservoir;
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    return outColor;
}



float3 evalDirectConnection(const ShadingData sd, const ShadingData laser_sd, const IMaterialInstance mi, const IMaterialInstance laser_mi, float pathLength, inout SampleGenerator sg){
    float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
    float toLaserHitDist = length(laser_sd.posW - sd.posW);
    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
    float3 L = mi.eval(sd, toLaserHitDir, sg) * laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower;
    L *= pathLengthImportance(pathLength + toLaserHitDist, tcurr);
    return L * V;
}


float3 evalEllipsoidalConnection(const ShadingData sd, const ShadingData laser_sd, const IMaterialInstance mi, const IMaterialInstance laser_mi, 
        float pathLength, inout SampleGenerator sg, inout LightSample lightSample, out float pdf){
    float ttarget = tcurr - pathLength;
    
    Ellipsoid E;
    float tSampled;
    float pdfT;
    
    samplePathLength(ttarget, sampleNext1D(sg), tSampled, pdfT);

    // build Ellipsoid and check if valid;
    if(!buildEllipsoidFromFoci(
        sd.posW, laser_sd.posW, tSampled,
        sd.getOrientedFaceNormal(), laser_sd.getOrientedFaceNormal(), E))
    {
        return float3(0.0);
    }

    uint triangleIndex;
    float trianglePdf;

    // randomly select triangle
    if(!emissiveSampler.sampleTriangleEllipsoid(
        E, sg, triangleIndex, trianglePdf)){
        return float3(0.0);
    }

    const EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);

    // check if sd or laser_sd is on triangle --> no need to check
    if(abs(dot(tri.normal, normalize(tri.posW[0] - sd.posW))) < 1e-5 
    || abs(dot(tri.normal, normalize(tri.posW[0] - laser_sd.posW))) < 1e-5){
        return float3(0.0);
    }

    // ellipsoid-triangle intersection
    SampleResultArea result = sampleOnTriangleEllipsoid(
        E,
        tri.posW[0], tri.posW[1], tri.posW[2],
        sampleNext1D(sg), sampleNext1D(sg));

    // valid result
    if(result.ok){
        pathLength = pathLength + length(sd.posW - result.p) + length(result.p - laser_sd.posW);

        // shoot ray to sampled point
        float hitT;
        HitInfo hit = traceRay(laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW), hitT);
        ShadingData second_sd = loadShadingData(hit, laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW));

        // valid point?
        if(hitT > 0 && hit.isValid()
            && abs(dot(second_sd.getOrientedFaceNormal(), tri.normal)) > 0.999 
            && abs(hitT - length(laser_sd.posW - result.p)) < 1e-3){
            
            let mi2 = gScene.materials.getMaterialInstance(second_sd, ExplicitLodTextureSampler(0));

            const float3 p1 = sd.posW;
            const float3 p2 = second_sd.posW;
            const float3 p3 = laser_sd.posW;

            const float3 n2 = second_sd.getOrientedFaceNormal();
            const float3 l12 = p2 - p1;
            const float3 l32 = p2 - p3;

            const float3 v12 = normalize(l12);
            const float3 v32 = normalize(l32);
            const float d12 = length(p2 - p1);
            const float d32 = length(p2 - p3);

            float3 f1 = mi.eval(sd, v12, sg);
            float3 f2 = mi2.eval(second_sd, -v12, sg);
            float3 f3 = laser_mi.eval(laser_sd, v32, sg);
            float n23 = max(dot(n2, -v32), 0.0);
            float G12 = dot(l12, l12);
            float G23 = dot(l32, l32);
            float3 f = f1 * f2 * f3 * n23 / (G12 * G23) * laserPower;
            float pdfA = trianglePdf * result.pdfA * pdfT;
            // f = f / max(pdfA, 1e-4f);

            bool V = traceVisibilityRay(sd.computeRayOrigin(), v12, d12);
            lightSample.p = p2;
            lightSample.n = n2;
            lightSample.hit = hit;
            pdf = pdfA;
            
            return f * V;
        }
    }
    return float3(0.0);
}


[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
    color = float3(color.x, color.x, color.x);

    gOutputColor[pixel] = float4(color / min(1.0, time_gate_window), 1.f);
}
