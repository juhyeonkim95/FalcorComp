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
import LaserLightSampler;


cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gRandomSeed;    // Frame count since scene was loaded.
    
    uint gPRNGDimension; // First available PRNG dimension.
    uint samplesPerPixel;
    uint2 gLaserHitVBufferRes;
    float specularRoughnessThreshold;
    float gTemporalHistoryLength;
    float gRoughTimeGateSampleRatio;
}

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
    float3 laserPrevOrigin;
    float3 laserPrevDirection;
}


// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional
Texture2D<float2> gMotionVector; // Optional
Texture2D<PackedHitInfo> gTemporalVBuffer;


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
static const float RECONNECTION_DISTANCE_THRESHOLD = 0.0; //1e-3;


bool traceVisibilityRay(const float3 origin, const float3 dir, const float distance)
{
    Ray visibilityRay = Ray(origin, dir, 0.0, distance - 1e-3f);
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
    
    bool useRoughTimeGate = time_gate_window_rough > time_gate_window;

    if (hit0.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        SampleGenerator sg_mi_sample = SampleGenerator(pixel, gFrameCount + 151);
        SampleGenerator sg_light = SampleGenerator(pixel, gFrameCount + 5713);
        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        BSDFProperties bsdfProperties0 = mi0.getProperties(sd0);
        float d01 = length(sd0.posW - primaryRayOrigin);

        //
        // Laser Hit Material
        //
        Reservoir reservoir = Reservoir();

        HitInfo rcVertexHit;
        HitInfo rcNextVertexHit;
        float3 rcNextVertexWi;

        uint M = useRoughTimeGate ? uint(samplesPerPixel * (1.0-gRoughTimeGateSampleRatio)) : samplesPerPixel;

        float maxPathLength = getMaxpathLength(tcurr);
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);






        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        // Initial Sample Generate
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////

        for(uint i=0; i<M; i++){
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);
            float3 postfixThroughput = float3(1.0f);
            float postfixPathLength = 0.0;

            //
            // (1) First Hit Material
            //
            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            float pathLength = d01;
            BSDFSample bsdfSample;

            HitInfo hit = hit0;
            float hitT;
            float p_brdf;
            
            bool is_prev_diffuse = bsdfProperties0.roughness > specularRoughnessThreshold;
            uint rcVertexPostBounce = 0;
            uint rcVertexBounce = 0;
            
            uint initRandomSeed = sg_mi_sample.getCurrentSeed();
            uint rcNextVertexRandomSeed;

#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
            {
                // -------------------- BSDF Sampling ----------------------
                uint rcNextVertexRandomSeedTemp = sg_mi_sample.getCurrentSeed();
                if(!mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                float pathLengthTemp = pathLength + hitT;
                if(any(throughput > 0.) && hit.isValid() && (pathLengthTemp < maxPathLength + 1e-2)){
                    // keep info
                    float3 prev_sd_posW = sd.posW;
                    
                    // Update new Hit Point
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    bool is_curr_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;

                    // need to re-calculate hitT
                    hitT = length(sd.posW - prev_sd_posW);
                    pathLength += hitT * sd.IoR;

                    //////////////////////////////
                    // RC Vertex Check
                    //////////////////////////////

                    // is this new rcVertex?
                    if(rcVertexPostBounce == 0 && is_curr_diffuse && is_prev_diffuse && hitT > RECONNECTION_DISTANCE_THRESHOLD){
                        rcVertexBounce = depth;
                        rcVertexHit = hit;
                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = max(hitT * hitT, kMinLightDistSqr);
                        p_brdf = bsdfSample.pdf * n21 / G12;
                    }
                    // previous one was rcVertex
                    else if(rcVertexPostBounce == 1){
                        rcNextVertexHit = hit;
                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = max(hitT * hitT, kMinLightDistSqr);
                        p_brdf *= bsdfSample.pdf * n21 / G12;
                    }
                    // previous, previous one was rcVertex
                    else if(rcVertexPostBounce == 2){
                        rcNextVertexWi = -bsdfSample.wo;
                        rcNextVertexRandomSeed = rcNextVertexRandomSeedTemp;
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT * sd.IoR;
                    }
                    // more than two bounce after rcVertex
                    else if(rcVertexPostBounce > 2) {
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT * sd.IoR;
                    }

                    ///////////////////////////////////////////////////////////////
                    // Sample Light & Eval Path Throughput
                    ///////////////////////////////////////////////////////////////
                    LightSample ls = {};
                    uint lightRandomSeed = sg_light.getCurrentSeed();
                    lls.generateLightSample(sg_light, ls);

                    // eval path throughput
                    float3 toLightDir = normalize(ls.posW() - sd.posW);
                    float toLightDist = length(ls.posW() - sd.posW);
                    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDist);
                    float3 L_mi = mi.eval(sd, toLightDir, sg);
                    float3 L_light = ls.evalLi(sd.posW, sg) * float(V);
                    float totalPathLength = pathLength + toLightDist + ls.laserT;
                    float pathLengthWeight = pathLengthImportance(totalPathLength, tcurr);
                    float3 f = throughput * L_mi * L_light * pathLengthWeight;

                    ///////////////////////////////////////////////////////////////
                    // Case 1. we have RC Vertex --> need to update reservoir info
                    ///////////////////////////////////////////////////////////////
                    if(rcVertexBounce > 0){
                        // temporarily update rc vertex info according to laser point
                        // 1. rcVertex
                        if(rcVertexPostBounce == 0){
                            rcNextVertexHit = ls.hit;
                            rcNextVertexWi = ls.dir;
                        }

                        // 2. rcVertex + 1
                        else if(rcVertexPostBounce == 1){
                            rcNextVertexWi = normalize(sd.posW - ls.posW());
                        }
                        float3 postfixf = postfixThroughput * L_light * max(0.0, dot(sd.getOrientedFaceNormal(), toLightDir));
                        float3 postfixIrradiance = (rcVertexPostBounce == 0) ? ls.Li : postfixf;
                        float postfixPathLengthFull = (rcVertexPostBounce == 0) ? ls.laserT : postfixPathLength + toLightDist + ls.laserT;
                        float3 f_full = f * p_brdf;
                        float weight = luminance(f) * 1.0 / M;
                        
                        if(reservoir.update(f_full, weight, 1, sg))
                        {
                            reservoir.rcVertexHit = rcVertexHit;
                            reservoir.rcNextVertexHit = rcNextVertexHit;
                            reservoir.rcNextVertexWi = rcNextVertexWi;
                            reservoir.rcNextVertexIrradiance = postfixIrradiance;
                            reservoir.rcNextVertexPathLength = postfixPathLengthFull;
                            reservoir.totalPathLength = totalPathLength;
                            reservoir.rcVertexBounce = rcVertexBounce;
                            reservoir.initRandomSeed = initRandomSeed;
                            #if IS_SCENE_DYNAMIC
                            reservoir.rcNextVertexBounce = rcVertexPostBounce;
                            reservoir.rcNextVertexRandomSeed = rcNextVertexRandomSeed;
                            reservoir.lightRandomSeed = lightRandomSeed;
                            #endif
                        }
                    } 
                    ///////////////////////////////////////////////////////////////
                    // Case 2. we don't have RC Vertex --> cannot be shared with other, but still need to add values.
                    ///////////////////////////////////////////////////////////////
                    else {
                        float weight = luminance(f) * 1.0 / M;
                        if(reservoir.update(f, weight, 1, sg))
                        {
                            reservoir.totalPathLength = totalPathLength;
                            reservoir.rcVertexBounce = 0;
                        }
                    }

                    is_prev_diffuse = is_curr_diffuse;
                    // update rcVertexPostBounce if we found rcvertex
                    if(rcVertexBounce > 0){
                        rcVertexPostBounce += 1;
                    }
                } else {
                    pathLength += 1000000;
                }
            }
#elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
            ///////////////////////////////////////////////////////////////
            // ELLIPSOID-(0) First Hit Point
            ///////////////////////////////////////////////////////////////
            LightSample ls = {};
            uint lightRandomSeed = sg_light.getCurrentSeed();
            lls.generateLightSample(sg_light, ls);

            const uint lobeTypes = mi.getLobeTypes(sd);
            const bool hasNonDeltaLobes = (lobeTypes & (uint)LobeType::NonDelta) != 0;
            #if USE_ELLIPSOIDAL_DIRECT_MIS
            if(hasNonDeltaLobes)
            #else
            if(is_prev_diffuse)
            #endif
            {
                // sample ellipse
                HitInfo ellipse_hit;
                float ellipse_pdfA;
                float direct_pdfA;

                float3 ellipse_posW;
                float3 ellipse_hit_irradiance;
                float3 L_light = 
                    sampleEllipsoidal(sd, ls, mi,
                        pathLength + ls.laserT, ellipse_hit, ellipse_posW, ellipse_hit_irradiance, 
                        ellipse_pdfA, direct_pdfA, sg);
                
                float3 L_mi = mi.eval(sd, normalize(ellipse_posW-sd.posW), sg);
                float totalPathLength = pathLength + length(sd.posW - ellipse_posW) + length(ellipse_posW - ls.posW()) + ls.laserT;
                float pathLengthWeight = pathLengthImportance(totalPathLength, tcurr);

                #if USE_ELLIPSOIDAL_DIRECT_MIS  
                float misWeight = (ellipse_pdfA > 0) ? ellipse_pdfA / (ellipse_pdfA + direct_pdfA) : 0.0;
                #else
                float misWeight = 1.0;
                #endif                
                
                float3 f_full = misWeight * throughput * L_mi * L_light * pathLengthWeight;

                float weight = (ellipse_pdfA == 0.0) ? 0.0 : luminance(f_full) / ellipse_pdfA * 1.0 / M;
                
                if(reservoir.update(f_full, weight, 1, sg))
                {
                    reservoir.rcVertexHit = ellipse_hit;
                    reservoir.rcNextVertexHit = ls.hit;
                    reservoir.rcNextVertexWi = ls.dir;
                    reservoir.rcNextVertexIrradiance = ls.Li;
                    reservoir.rcNextVertexPathLength = ls.laserT;
                    reservoir.totalPathLength = totalPathLength;
                    reservoir.rcVertexBounce = 1;
                    reservoir.initRandomSeed = initRandomSeed;
                    #if IS_SCENE_DYNAMIC
                    reservoir.rcNextVertexBounce = rcVertexPostBounce;
                    reservoir.rcNextVertexRandomSeed = rcNextVertexRandomSeed;
                    reservoir.lightRandomSeed = lightRandomSeed;
                    #endif
                }
            }

            ///////////////////////////////////////////////////////////////
            // ELLIPSOID-(1) After First Hit Point
            ///////////////////////////////////////////////////////////////
            #if USE_ELLIPSOIDAL_DIRECT_MIS
            for(uint depth=1; depth < kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
            #else
            for(uint depth=1; ((depth<(kMaxBounces-1)) || ((depth==(kMaxBounces-1)) && !is_prev_diffuse)) && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
            #endif
            {
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                // pathLength += hitT;
                float pathLengthNotExact = pathLength + hitT;

                if(any(throughput > 0.) && hit.isValid() && (pathLengthNotExact < maxPathLength + 1e-2)){
                    // keep info
                    float3 prev_sd_posW = sd.posW;
                    float3 prev_sd_N = sd.getOrientedFaceNormal();

                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    bool is_curr_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;
                    
                    const uint lobeTypes = mi.getLobeTypes(sd);
                    const bool hasNonDeltaLobes = (lobeTypes & (uint)LobeType::NonDelta) != 0;
                    hitT = length(sd.posW - prev_sd_posW);
                    pathLength += hitT * sd.IoR;
                    
                    //////////////////////////////
                    // RC Vertex Check
                    //////////////////////////////
                    {
                        // is this new rcVertex?
                        if(rcVertexPostBounce == 0 && is_curr_diffuse && is_prev_diffuse){
                            rcVertexBounce = depth;
                            rcVertexHit = hit;
                            float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                            float G12 = hitT * hitT;
                            p_brdf = (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;
                        }
                        // previous one was rcVertex
                        else if(rcVertexPostBounce == 1){
                            rcNextVertexHit = hit;
                            float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                            float G12 = hitT * hitT;
                            p_brdf *= (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;
                        }
                        // previous, previous one was rcVertex
                        else if(rcVertexPostBounce == 2){
                            rcNextVertexWi = -bsdfSample.wo;
                            postfixThroughput *= bsdfSample.weight;
                            postfixPathLength += hitT* sd.IoR;
                        }
                        // more than two bounce after rcVertex
                        else if(rcVertexPostBounce > 2) {
                            postfixThroughput *= bsdfSample.weight;
                            postfixPathLength += hitT* sd.IoR;
                        }
                    }

                    ///////////////////////////////////////////////////////////////
                    // Sample Light
                    ///////////////////////////////////////////////////////////////
                    LightSample ls = {};
                    uint lightRandomSeed = sg_light.getCurrentSeed();
                    lls.generateLightSample(sg_light, ls);
                    
                    ///////////////////////////////////////////////////////////////
                    // ELLIPSOID-(1) - A. Perform ellipsoidal (only if we have left path bounce)
                    ///////////////////////////////////////////////////////////////
                    #if USE_ELLIPSOIDAL_DIRECT_MIS
                    if((depth < (kMaxBounces - 1)) && hasNonDeltaLobes)
                    #else
                    if((depth < (kMaxBounces - 1)) && is_curr_diffuse)
                    #endif
                    {
                        // sample ellipse
                        HitInfo ellipse_hit;
                        float ellipse_pdfA = 0.0f;
                        float direct_pdfA = 0.0f;
                        float3 ellipse_posW = float3(0.0);
                        float3 ellipse_hit_irradiance = float3(0.0);
                        float3 L_light = sampleEllipsoidal(sd, ls, mi, 
                            pathLength + ls.laserT, ellipse_hit, ellipse_posW, 
                            ellipse_hit_irradiance, ellipse_pdfA, direct_pdfA,
                            sg);
                        if(ellipse_pdfA > 0.0) L_light /= ellipse_pdfA;
                        float ellipselaserT = ls.laserT + length(ellipse_posW - ls.posW());

                        // eval path throughput
                        float3 L_mi = mi.eval(sd, normalize(ellipse_posW-sd.posW), sg);
                        float totalPathLength = pathLength 
                            + length(sd.posW - ellipse_posW) + ellipselaserT;
                        float pathLengthWeight = pathLengthImportance(totalPathLength, tcurr);
                        float3 f = throughput * L_mi * L_light * pathLengthWeight;

                        #if USE_ELLIPSOIDAL_DIRECT_MIS
                        // apply MIS
                        float misWeight = (ellipse_pdfA > 0) ? ellipse_pdfA / (ellipse_pdfA + direct_pdfA) : 0.0;
                        #else
                        float misWeight = 1.0;
                        #endif

                        f *= misWeight;

                        ///////////////////////////////////////////////////////////////
                        // Case 1. we have RC Vertex --> need to update reservoir info
                        ///////////////////////////////////////////////////////////////
                        if(rcVertexBounce > 0){
                            // temporarily update rc vertex info according to sampled ellipse
                            // 1. rcVertex
                            if(rcVertexPostBounce == 0){
                                rcNextVertexHit = ellipse_hit;
                                rcNextVertexWi = normalize(ellipse_posW - ls.posW());
                            }
                            // 2. rcVertex + 1
                            else if(rcVertexPostBounce == 1){
                                rcNextVertexWi = normalize(sd.posW - ellipse_posW);
                            }

                            float3 postfixf = postfixThroughput * L_light * max(0.0, dot(sd.getOrientedFaceNormal(), normalize(ellipse_posW-sd.posW)));
                            float3 postfixIrradiance = (rcVertexPostBounce == 0) ? ellipse_hit_irradiance : postfixf;
                            float postfixPathLengthFull = (rcVertexPostBounce == 0) ? ellipselaserT : postfixPathLength + length(sd.posW - ellipse_posW) + ellipselaserT;
                            
                            float3 f_full = f * p_brdf * ((rcVertexPostBounce == 0) ? ellipse_pdfA : 1.0);
                            
                            float weight = luminance(f) * 1.0 / M;
                            
                            if(reservoir.update(f_full, weight, 1, sg))
                            {
                                reservoir.rcVertexHit = rcVertexHit;
                                reservoir.rcNextVertexHit = rcNextVertexHit;
                                reservoir.rcNextVertexWi = rcNextVertexWi;
                                reservoir.rcNextVertexIrradiance = postfixIrradiance;
                                reservoir.rcNextVertexPathLength = postfixPathLengthFull;
                                reservoir.totalPathLength = totalPathLength;
                                reservoir.rcVertexBounce = rcVertexBounce;
                                reservoir.initRandomSeed = initRandomSeed;
                                #if IS_SCENE_DYNAMIC
                                reservoir.rcNextVertexBounce = rcVertexPostBounce + 1; // this is ellipsoid
                                reservoir.rcNextVertexRandomSeed = rcNextVertexRandomSeed;
                                reservoir.lightRandomSeed = lightRandomSeed;
                                #endif            
                            }
                        }
                        ///////////////////////////////////////////////////////////////
                        // Case 2. we don't have RC Vertex --> cannot be shared with other, but still need to add values.
                        ///////////////////////////////////////////////////////////////
                        else {
                            float weight = luminance(f) * 1.0 / M;
                            if(reservoir.update(f, weight, 1, sg))
                            {
                                reservoir.rcVertexBounce = 0;
                            }
                        }
                    }

                    ///////////////////////////////////////////////////////////////
                    // ELLIPSOID-(1) - B. Perform direct
                    ///////////////////////////////////////////////////////////////
                    #if USE_ELLIPSOIDAL_DIRECT_MIS
                    if(hasNonDeltaLobes)
                    #else
                    if(!is_prev_diffuse && hasNonDeltaLobes)
                    #endif
                    {
                        // eval path throughput
                        float3 toLightDir = normalize(ls.posW() - sd.posW);
                        float toLightDist = length(ls.posW() - sd.posW);
                        bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDist);
                        float3 L_mi = mi.eval(sd, toLightDir, sg);
                        float3 L_light = ls.evalLi(sd.posW, sg) * float(V);
                        float totalPathLength = pathLength + toLightDist + ls.laserT;
                        float pathLengthWeight = pathLengthImportance(totalPathLength, tcurr);
                        float3 f = throughput * L_mi * L_light * pathLengthWeight;

                        #if USE_ELLIPSOIDAL_DIRECT_MIS
                        // apply MIS
                        // (1) Direct
                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = hitT * hitT;
                        float direct_pdfA = (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;

                        // (2) Ellipsoid
                        Ellipsoid E;
                        float ellipseLength = length(sd.posW - prev_sd_posW) + length(sd.posW - ls.posW());
                        float ellipse_pdfA = 0.0;
                        if(buildEllipsoidFromFoci(prev_sd_posW, ls.posW(), ellipseLength,
                            prev_sd_N, ls.getOrientedFaceNormal(), E))
                        {
                            ellipse_pdfA = evalEllipsoidPdf(E, hit, sd, pathLength + ls.laserT - hitT);
                        };
                        
                        float misWeight = (direct_pdfA > 0) ? direct_pdfA / (ellipse_pdfA + direct_pdfA) : 0.0;
                        f *= misWeight;
                        #endif

                        ///////////////////////////////////////////////////////////////
                        // Case 1. we have RC Vertex --> need to update reservoir info
                        ///////////////////////////////////////////////////////////////
                        if(rcVertexBounce > 0){
                            // temporarily update rc vertex info according to laser point
                            // 1. rcVertex
                            if(rcVertexPostBounce == 0){
                                rcNextVertexHit = ls.hit;
                                rcNextVertexWi = ls.dir;
                            }
                            // 2. rcVertex + 1
                            else if(rcVertexPostBounce == 1){
                                rcNextVertexWi = normalize(sd.posW - ls.posW());
                            }

                            float3 postfixf = postfixThroughput * L_light * max(0.0, dot(sd.getOrientedFaceNormal(), toLightDir));
                            float3 postfixIrradiance = (rcVertexPostBounce == 0) ? ls.Li : postfixf;
                            float postfixPathLengthFull = (rcVertexPostBounce == 0) ? ls.laserT : postfixPathLength + toLightDist + ls.laserT;
                            
                            float3 f_full = f * p_brdf;
                            float weight = luminance(f) * 1.0 / M;

                            if(reservoir.update(f_full, weight, 1, sg))
                            {
                                reservoir.rcVertexHit = rcVertexHit;
                                reservoir.rcNextVertexHit = rcNextVertexHit;
                                reservoir.rcNextVertexWi = rcNextVertexWi;
                                reservoir.rcNextVertexIrradiance = postfixIrradiance;
                                reservoir.rcNextVertexPathLength = postfixPathLengthFull;
                                reservoir.totalPathLength = totalPathLength;
                                reservoir.rcVertexBounce = rcVertexBounce;
                                reservoir.initRandomSeed = initRandomSeed;
                            }
                        }
                        ///////////////////////////////////////////////////////////////
                        // Case 2. we don't have RC Vertex --> cannot be shared with other, but still need to add values.
                        ///////////////////////////////////////////////////////////////
                        else {
                            float weight = luminance(f) * 1.0 / M;
                            if(reservoir.update(f, weight, 1, sg))
                            {
                                reservoir.rcVertexBounce = 0;
                            }
                        }
                    }

                    // update to next path segment
                    is_prev_diffuse = is_curr_diffuse;

                    // update rcvertexpostbounce if we found rcvertex
                    if(rcVertexBounce > 0){
                        rcVertexPostBounce += 1;
                    }
                }
            }
#endif
        }
        // finalize current reservoir
        float pHat = luminance(reservoir.f);
        reservoir.W = pHat > 0 ? 1.0f / pHat * reservoir.wSum : 0.0;
        
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        // refine?
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////

        if(useRoughTimeGate)
        {
            Reservoir reservoirRough = Reservoir();

            HitInfo rcVertexHit;
            HitInfo rcNextVertexHit;
            float3 rcNextVertexWi;

            uint M = uint(samplesPerPixel * gRoughTimeGateSampleRatio);

            float maxPathLength = getMaxpathLength(tcurr, true);
            LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);

            for(uint i=0; i<M; i++){
                float3 result = float3(0.0f);
                float3 throughput = float3(1.0f);
                float3 postfixThroughput = float3(1.0f);
                float postfixPathLength = 0.0;

                //
                // (1) First Hit Material
                //
                ShadingData sd = sd0;
                IMaterialInstance mi = mi0;
                float pathLength = d01;
                BSDFSample bsdfSample;

                HitInfo hit = hit0;
                float hitT;
                float p_brdf;
                
                bool is_prev_diffuse = bsdfProperties0.roughness > specularRoughnessThreshold;
                uint rcVertexPostBounce = 0;
                uint rcVertexBounce = 0;
                
                uint initRandomSeed = sg_mi_sample.getCurrentSeed();
                uint rcNextVertexRandomSeed;

                for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
                {
                    // -------------------- BSDF Sampling ----------------------
                    uint rcNextVertexRandomSeedTemp = sg_mi_sample.getCurrentSeed();
                    if(!mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling)){
                        break;
                    }
                    throughput *= bsdfSample.weight;
                    bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                    hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                    float pathLengthTemp = pathLength + hitT;
                    if(any(throughput > 0.) && hit.isValid() && (pathLengthTemp < maxPathLength + 1e-2)){
                        // keep info
                        float3 prev_sd_posW = sd.posW;
                        
                        // Update new Hit Point
                        sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                        mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                        bool is_curr_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;

                        // need to re-calculate hitT
                        hitT = length(sd.posW - prev_sd_posW);
                        pathLength += hitT;

                        //////////////////////////////
                        // RC Vertex Check
                        //////////////////////////////

                        // is this new rcVertex?
                        if(rcVertexPostBounce == 0 && is_curr_diffuse && is_prev_diffuse && hitT > RECONNECTION_DISTANCE_THRESHOLD){
                            rcVertexBounce = depth;
                            rcVertexHit = hit;
                            float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                            float G12 = max(hitT * hitT, kMinLightDistSqr);
                            p_brdf = bsdfSample.pdf * n21 / G12;
                        }
                        // previous one was rcVertex
                        else if(rcVertexPostBounce == 1){
                            rcNextVertexHit = hit;
                            float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                            float G12 = max(hitT * hitT, kMinLightDistSqr);
                            p_brdf *= bsdfSample.pdf * n21 / G12;
                        }
                        // previous, previous one was rcVertex
                        else if(rcVertexPostBounce == 2){
                            rcNextVertexWi = -bsdfSample.wo;
                            rcNextVertexRandomSeed = rcNextVertexRandomSeedTemp;
                            postfixThroughput *= bsdfSample.weight;
                            postfixPathLength += hitT;
                        }
                        // more than two bounce after rcVertex
                        else if(rcVertexPostBounce > 2) {
                            postfixThroughput *= bsdfSample.weight;
                            postfixPathLength += hitT;
                        }

                        ///////////////////////////////////////////////////////////////
                        // Sample Light & Eval Path Throughput
                        ///////////////////////////////////////////////////////////////
                        LightSample ls = {};
                        uint lightRandomSeed = sg_light.getCurrentSeed();
                        lls.generateLightSample(sg_light, ls);

                        // eval path throughput
                        float3 toLightDir = normalize(ls.posW() - sd.posW);
                        float toLightDist = length(ls.posW() - sd.posW);
                        bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDist);
                        float3 L_mi = mi.eval(sd, toLightDir, sg);
                        float3 L_light = ls.evalLi(sd.posW, sg) * float(V);
                        float totalPathLength = pathLength + toLightDist + ls.laserT;
                        float pathLengthWeight = pathLengthImportance(totalPathLength, tcurr, true);
                        float3 f = throughput * L_mi * L_light * pathLengthWeight;

                        ///////////////////////////////////////////////////////////////
                        // Case 1. we have RC Vertex --> need to update reservoir info
                        ///////////////////////////////////////////////////////////////
                        if(rcVertexBounce > 0){
                            // temporarily update rc vertex info according to laser point
                            // 1. rcVertex
                            if(rcVertexPostBounce == 0){
                                rcNextVertexHit = ls.hit;
                                rcNextVertexWi = ls.dir;
                            }

                            // 2. rcVertex + 1
                            else if(rcVertexPostBounce == 1){
                                rcNextVertexWi = normalize(sd.posW - ls.posW());
                            }
                            float3 postfixf = postfixThroughput * L_light * max(0.0, dot(sd.getOrientedFaceNormal(), toLightDir));
                            float3 postfixIrradiance = (rcVertexPostBounce == 0) ? ls.Li : postfixf;
                            float postfixPathLengthFull = (rcVertexPostBounce == 0) ? ls.laserT : postfixPathLength + toLightDist + ls.laserT;
                            float3 f_full = f * p_brdf;
                            float weight = luminance(f) * 1.0 / M;
                            
                            if(reservoirRough.update(f_full, weight, 1, sg))
                            {
                                reservoirRough.rcVertexHit = rcVertexHit;
                                reservoirRough.rcNextVertexHit = rcNextVertexHit;
                                reservoirRough.rcNextVertexWi = rcNextVertexWi;
                                reservoirRough.rcNextVertexIrradiance = postfixIrradiance;
                                reservoirRough.rcNextVertexPathLength = postfixPathLengthFull;
                                reservoirRough.totalPathLength = totalPathLength;
                                reservoirRough.rcVertexBounce = rcVertexBounce;
                                reservoirRough.initRandomSeed = initRandomSeed;
                                #if IS_SCENE_DYNAMIC
                                reservoirRough.rcNextVertexBounce = rcVertexPostBounce;
                                reservoirRough.rcNextVertexRandomSeed = rcNextVertexRandomSeed;
                                reservoirRough.lightRandomSeed = lightRandomSeed;
                                #endif
                            }
                        } 
                        ///////////////////////////////////////////////////////////////
                        // Case 2. we don't have RC Vertex --> cannot be shared with other, but still need to add values.
                        ///////////////////////////////////////////////////////////////
                        else {
                            float weight = luminance(f) * 1.0 / M;
                            if(reservoirRough.update(f, weight, 1, sg))
                            {
                                reservoirRough.totalPathLength = totalPathLength;
                                reservoirRough.rcVertexBounce = 0;
                            }
                        }

                        is_prev_diffuse = is_curr_diffuse;
                        // update rcVertexPostBounce if we found rcvertex
                        if(rcVertexBounce > 0){
                            rcVertexPostBounce += 1;
                        }
                    } else {
                        pathLength += 1000000;
                    }
                }
            }

            // finalize current reservoir
            float pHat = luminance(reservoirRough.f);
            reservoirRough.W = pHat > 0 ? 1.0f / pHat * reservoirRough.wSum : 0.0;
            

            float K = time_gate_window_rough / time_gate_window;

            Reservoir dstReservoir;
            reservoir.M = 1.0 - gRoughTimeGateSampleRatio;
            reservoirRough.M = gRoughTimeGateSampleRatio;

            // (1) rough as curr
            combine_reservoir_with_shiftmapping(
                dstReservoir,
                reservoirRough,
                reservoir.M,
                sd0, mi0, d01,
                tcurr, tcurr,
                1.0 / K,
                false, // this is not canonical
                laserOrigin,
                laserDirection,
                sg
            );
            // (2) curr as curr
            combine_reservoir_with_shiftmapping(
                dstReservoir,
                reservoir,
                reservoirRough.M,
                sd0, mi0, d01,
                tcurr, tcurr,
                K,
                true, // this is canonical
                laserOrigin,
                laserDirection,
                sg
            );
            
            // finalize current reservoir
            float pHatFinal = luminance(dstReservoir.f);
            dstReservoir.W = pHatFinal > 0 ? 1.0f / pHatFinal * dstReservoir.wSum : 0.0;
            
            reservoir = dstReservoir;
        }

        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        // Temporal Reuse
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        #if USE_TEMPORAL_REUSE
        #if IS_SCENE_DYNAMIC
        uint2 prevPixel = uint2(pixel) + gMotionVector[pixel] * frameDim + (sampleNext2D(sg) * 1.f - 0.f);
        bool isPrevPixelValid = (prevPixel.x >=0) && (prevPixel.x < frameDim.x) && (prevPixel.y >=0) && (prevPixel.y < frameDim.y);

        if(isPrevPixelValid && gFrameCount > 0)
        {
            // get prev hit info
            const HitInfo hit0prev = HitInfo(gTemporalVBuffer[prevPixel]);
            if(hit0prev.isValid()){
                // generate previous camera ray
                Ray rayPrev = gScene.camera.computeRayPinholePrevFrame(prevPixel, frameDim);
                
                ShadingData sd0prev = loadShadingData(hit0prev, rayPrev.origin, rayPrev.dir);
                IMaterialInstance mi0prev = gScene.materials.getMaterialInstance(sd0prev, ExplicitLodTextureSampler(0.f));
                float d01prev = length(rayPrev.origin - sd0prev.posW);

                uint linearizedPixelPrev = prevPixel.y * frameDim.x + prevPixel.x;
                Reservoir prevReservoir = prevReservoirs[linearizedPixelPrev];

                // M capping
                if(gTemporalHistoryLength > 0){
                    prevReservoir.M = min(prevReservoir.M, gTemporalHistoryLength * samplesPerPixel);
                }

                if(!isValidGeometry(sd0, sd0prev, d01, d01prev)){
                    prevReservoir.M = 0.0;
                }
                
                Reservoir dstReservoir;

                // (1) prev as curr
                // (1) - 1 transform prev reservoir to curr
                Reservoir prevReservoirAsCurr = prevReservoir;
                update_reservoir_for_dynamic_scene(prevReservoirAsCurr, lls, sg);

                // (1) - 2 add prev as curr
                combine_reservoir_with_shiftmapping_for_dynamic_scene(
                    dstReservoir,
                    prevReservoirAsCurr,
                    prevReservoir,
                    reservoir.M,
                    sd0, mi0, d01,
                    tcurr, tprev,
                    1.0,
                    false, // this is not canonical
                    laserOrigin,
                    laserDirection,
                    sg
                );

                // (2) curr as curr
                // (2) - 1 transform curr reservoir to prev
                Reservoir currReservoirAsPrev = reservoir;
                LaserLightSampler llsPrev = LaserLightSampler(laserPrevOrigin, laserPrevDirection, laserCosAngle, laserPower);
                update_reservoir_for_dynamic_scene(currReservoirAsPrev, llsPrev, sg);
                
                // (2) - 2 add curr as curr
                combine_reservoir_with_shiftmapping_for_dynamic_scene(
                    dstReservoir,
                    currReservoirAsPrev,
                    reservoir,
                    prevReservoir.M,
                    sd0prev, mi0prev, d01prev,
                    tprev, tcurr,
                    1.0,
                    true, // this is canonical
                    laserPrevOrigin,
                    laserPrevDirection,
                    sg
                );
                
                float pHat = luminance(dstReservoir.f);
                dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
                reservoir = dstReservoir;
            }
        }
        #else
        if(gFrameCount > 0)
        {
            // generate previous camera ray
            Ray rayPrev = gScene.camera.computeRayPinholePrevFrame(pixel, frameDim);
            uint linearizedPixelPrev = pixel.y * frameDim.x + pixel.x;
            Reservoir prevReservoir = prevReservoirs[linearizedPixelPrev];

            // M capping
            if(gTemporalHistoryLength > 0){
                prevReservoir.M = min(prevReservoir.M, gTemporalHistoryLength * samplesPerPixel);
            }
            
            Reservoir dstReservoir;

            // (1) prev as curr
            combine_reservoir_with_shiftmapping(
                dstReservoir,
                prevReservoir,
                reservoir.M,
                sd0, mi0, d01,
                tcurr, tprev,
                1.0,
                false, // this is not canonical
                laserOrigin,
                laserDirection,
                sg
            );
            // (2) curr as curr
            combine_reservoir_with_shiftmapping(
                dstReservoir,
                reservoir,
                prevReservoir.M,
                sd0, mi0, d01,
                tprev, tcurr,
                1.0,
                true, // this is canonical
                laserPrevOrigin,
                laserPrevDirection,
                sg
            );
            float pHat = luminance(dstReservoir.f);
            dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
            reservoir = dstReservoir;
        }
        #endif
        #endif
        
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

float3 sampleEllipsoidal(
    const ShadingData sd, 
    const LightSample ls, 
    const IMaterialInstance mi, 
    float pathLength, 
    out HitInfo hit,
    out float3 hitPosW,
    out float3 hitIrradiance,
    out float ellipsePdfA,
    out float directPdfA,
    inout SampleGenerator sg
){

    hit = {};
    hitPosW = {};
    hitIrradiance = {};
    ellipsePdfA = 0.0f;
    directPdfA = 0.0f;

    float ttarget = tcurr - pathLength;
    
    Ellipsoid E;
    float tSampled;
    float pdfT;
    
    samplePathLength(ttarget, sampleNext1D(sg), tSampled, pdfT);

    // build Ellipsoid and check if valid;
    if(!buildEllipsoidFromFoci(
        sd.posW, ls.posW(), tSampled,
        sd.getOrientedFaceNormal(), ls.getOrientedFaceNormal(), E))
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

    // check if sd or ls is on triangle --> no need to check
    if(abs(dot(tri.normal, normalize(tri.posW[0] - sd.posW))) < 1e-4 
        || abs(dot(tri.normal, normalize(tri.posW[0] - ls.posW()))) < 1e-4){
        return float3(0.0);
    }

    // ellipsoid-triangle intersection
    SampleResultArea result = sampleOnTriangleEllipsoid(
        E,
        tri.posW[0], tri.posW[1], tri.posW[2],
        sampleNext1D(sg), sampleNext1D(sg));
    
    // valid result
    if(result.ok && !isnan(result.pdfA) && !isinf(result.pdfA)){
        // pathLength = pathLength + length(sd.posW - result.p) + length(result.p - ls.posW());

        // shoot ray to sampled point
        float hitT;
        hit = traceRay(sd.computeRayOrigin(), normalize(result.p - sd.posW), hitT);
        ShadingData second_sd = loadShadingData(hit, sd.computeRayOrigin(), normalize(result.p - sd.posW));
        
        // valid point?
        if(hitT > 0 && hit.isValid()
            && abs(dot(second_sd.getOrientedFaceNormal(), tri.normal)) > 0.999 
            && abs(hitT - length(sd.posW - result.p)) < 1e-3){
            
            
            let mi2 = gScene.materials.getMaterialInstance(second_sd, ExplicitLodTextureSampler(0));

            const float3 p1 = sd.posW;
            const float3 p2 = second_sd.posW;
            const float3 p3 = ls.posW();
            hitPosW = p2;

            const float3 n2 = second_sd.getOrientedFaceNormal();
            const float3 l12 = p2 - p1;
            const float3 l23 = p3 - p2;

            const float3 v12 = normalize(l12);
            const float3 v23 = normalize(l23);
            const float d12 = length(p2 - p1);
            const float d23 = length(p3 - p2);

            float3 f2 = mi2.eval(second_sd, v23, sg);
            float3 Li = ls.evalLi(p2, sg);

            float n21 = max(dot(n2, -v12), 0.0);
            float n23 = max(dot(n2, v23), 0.0);
            float G12 = max(dot(l12, l12), kMinLightDistSqr);
            
            if(n23 < 1e-6 || n21 < 1e-6){
                n23 = 0.0;
                n21 = 0.0;
            }

            float3 f = f2 * Li * n21 / (G12);
            hitIrradiance = Li * n23;
            
            // Eval Pdfs
            ellipsePdfA = trianglePdf * result.pdfA * pdfT;
            if(ellipsePdfA < 1e-9) return float3(0.0);

            float directpdf = mi.evalPdf(sd, normalize(second_sd.posW - sd.posW));
            directPdfA = (G12 < 1e-9) ? 0.0 : directpdf * n21 / G12;

            bool V = traceVisibilityRay(second_sd.computeRayOrigin(), v23, d23);
            return f * V;
        }
    }
    return float3(0.0);
}


bool isValidGeometry(const ShadingData sd1, const ShadingData sd2, float d1, float d2){
    const float normalThreshold = 0.7f;
    const float depthThreshold = 0.1f;

    return  dot(sd1.getOrientedFaceNormal(), sd2.getOrientedFaceNormal()) > normalThreshold 
                && abs(d1 - d2) < depthThreshold * d1 && 
                (sd1.materialID == sd2.materialID);
}


float evalEllipsoidPdf(Ellipsoid E, const HitInfo hit, const ShadingData sd, float pathLength){
    // Prepare hit point struct with data needed for emissive light PDF evaluation.
    TriangleLightHit trilighthit;
    TriangleHit triangleHit = hit.getTriangleHit();
    trilighthit.triangleIndex = gScene.triCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
    trilighthit.posW = sd.posW;
    trilighthit.normalW = sd.getOrientedFaceNormal();
    
    EmissiveTriangle tri = gScene.triCollection.getTriangle(trilighthit.triangleIndex);
    
    float ttarget = tcurr - pathLength;

    float pdfTri = emissiveSampler.evalPdfEllipsoid(E, trilighthit);

    SampleResultArea result = sampleOnTriangleEllipsoid(E, tri.posW[0], tri.posW[1], tri.posW[2], 0.5, 0.5);

    float pdfArc = (result.ok && !isinf(result.pdfA) && !isnan(result.pdfA)) ? result.pdfA : 0.0;//pdfUniformEllipsoidTriangleArc(E, tri.posW[0], tri.posW[1], tri.posW[2]);
    float pdfTime = evalPdfPathLength(ttarget, E.t);
    float pdfA = pdfTime * pdfArc * pdfTri;
    return pdfA;
}


[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
    gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
}