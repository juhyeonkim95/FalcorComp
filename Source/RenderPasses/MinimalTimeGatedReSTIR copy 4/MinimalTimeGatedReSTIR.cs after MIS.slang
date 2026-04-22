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
    uint gRandomSeed;    // Frame count since scene was loaded.
    
    uint gPRNGDimension; // First available PRNG dimension.
    uint samplesPerPixel;
    uint2 gLaserHitVBufferRes;
    float specularRoughnessThreshold;
    float gTemporalHistoryLength;
}

cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
    float laserCosAngle;
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
        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        BSDFProperties bsdfProperties0 = mi0.getProperties(sd0);
        float d01 = length(sd0.posW - primaryRayOrigin);

        //
        // Laser Hit Material
        //
        float3 laser_normal = laserDirection;
        float3 laser_bitangent = perp_stark_onb(laser_normal);
        float3 laser_tangent = cross(laser_bitangent, laser_normal);

        Reservoir reservoir = Reservoir();

        HitInfo rcVertexHit;
        HitInfo rcNextVertexHit;
        float3 rcNextVertexWi;

        uint M = samplesPerPixel;

        float maxPathLength = getMaxpathLength(tcurr);

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
            
            float rcVertexPathLength = 0.0;
            uint initRandomSeed = sg_mi_sample.getCurrentSeed();
            
#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++){
                // -------------------- BSDF Sampling ----------------------
                mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling);
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                pathLength += hitT;

                if(any(throughput > 0.) && hit.isValid() && (pathLength < maxPathLength)){
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    bool is_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;

                    // sample light
                    float2 lightuv = sampleNext2D(sg);
                    float3 local = sample_cone(lightuv, laserCosAngle);
                    float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
                    float laserT;
                    HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
                    ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
                    let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
                    
                    if(is_prev_diffuse && is_diffuse && (rcVertexPostBounce == 0)){
                        rcVertexBounce = depth;
                        rcVertexPathLength = pathLength;
                        rcVertexPostBounce += 1;
                        rcVertexHit = hit;
                        rcNextVertexHit = laserhit;
                        rcNextVertexWi = laser_d;
                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = hitT * hitT;
                        p_brdf = (G12 == 0.0) ? 0.0 : bsdfSample.pdf * n21 / G12;
                    }
                    else if(rcVertexPostBounce == 1){
                        rcVertexPostBounce += 1;
                        rcNextVertexHit = hit;
                        rcNextVertexWi = normalize(sd.posW - laser_sd.posW);

                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = hitT * hitT;
                        p_brdf *= (G12 == 0.0) ? 0.0 : bsdfSample.pdf * n21 / G12;
                    }
                    else if(rcVertexPostBounce == 2){
                        rcVertexPostBounce += 1;
                        rcNextVertexWi = -bsdfSample.wo;
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    } else if(rcVertexPostBounce > 2) {
                        rcVertexPostBounce += 1;
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    }

                    is_prev_diffuse = is_diffuse;

                    float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
                    float toLaserHitDist = length(laser_sd.posW - sd.posW);
                    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
                    float3 L_mi = mi.eval(sd, toLaserHitDir, sg);
                    float3 L_laser_mi = laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower * float(V);
                    float pathLengthTotal = pathLength + toLaserHitDist + laserT;

                    float pathLengthWeight = pathLengthImportance(pathLengthTotal, tcurr, useRoughTimeGate);

                    float3 f = throughput * L_mi * L_laser_mi * pathLengthWeight;
                    float3 postfixf = postfixThroughput * L_laser_mi * max(0.0, dot(sd.getOrientedFaceNormal(), toLaserHitDir));
                    float3 postfixIrradiance = (rcVertexPostBounce == 1) ? laserPower : postfixf;
                    float postfixPathLengthFull = (rcVertexPostBounce == 1) ? laserT : postfixPathLength + toLaserHitDist + laserT;
// #if kUseSingleChannel == true
//                     f = float3(f.x);
//                     postfixIrradiance = float3(postfixIrradiance.x);
// #endif
                    float3 f_full = f * p_brdf;
                    // if(p_brdf < 1e-6)
                    //     f_full *= 0.0;
                        
                    float weight = luminance(f) * 1.0 / M;


                    if(reservoir.update(f_full, weight, 1, sg))
                    {
                        if(rcVertexPostBounce > 0) {
                            reservoir.rcVertexHit = rcVertexHit;
                            reservoir.rcNextVertexHit = rcNextVertexHit;
                            reservoir.rcNextVertexWi = rcNextVertexWi;
                            reservoir.rcNextVertexIrradiance = postfixIrradiance;
                            reservoir.rcNextVertexPathLength = postfixPathLengthFull;
                            reservoir.rcVertexPathLength = rcVertexPathLength;
                            reservoir.rcVertexBounce = rcVertexBounce;
                            reservoir.initRandomSeed = initRandomSeed;
                        } else {
                            reservoir.rcVertexBounce = 0;
                        }
                        
                    }
                }
            }
#elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
            // sample light
            float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
            float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
            float laserT;
            HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
            ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
            let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));

            if(is_prev_diffuse){
                // sample ellipse
                HitInfo ellipse_hit;
                float ellipse_pdfA;
                float direct_pdfA;

                float3 ellipse_posW;
                float3 ellipse_f_temp;
                float3 L_laser_mi = 
                    sampleEllipsoidal(sd, laser_sd, mi, laser_mi,
                        pathLength + laserT, ellipse_hit, ellipse_posW, ellipse_f_temp, 
                        ellipse_pdfA, direct_pdfA, sg);
                
                float3 L_mi = mi.eval(sd, normalize(ellipse_posW-sd.posW), sg);
                float pathLengthWeight = pathLengthImportance(pathLength 
                    + length(sd.posW - ellipse_posW) + length(ellipse_posW - laser_sd.posW) + laserT, tcurr, useRoughTimeGate);
                
                float misWeight = (ellipse_pdfA > 0) ? ellipse_pdfA / (ellipse_pdfA + direct_pdfA) : 0.0;

                float3 f_full = misWeight * throughput * L_mi * L_laser_mi * pathLengthWeight;
                float weight = (ellipse_pdfA == 0.0) ? 0.0 : luminance(f_full) / ellipse_pdfA * 1.0 / M;
                
                if(reservoir.update(f_full, weight, 1, sg))
                {
                    reservoir.rcVertexHit = ellipse_hit;
                    reservoir.rcNextVertexHit = laserhit;
                    reservoir.rcNextVertexWi = laser_d;
                    reservoir.rcNextVertexIrradiance = laserPower;
                    reservoir.rcNextVertexPathLength = laserT;
                    reservoir.rcVertexPathLength = pathLength + length(sd.posW - ellipse_posW);
                    reservoir.rcVertexBounce = 1;
                    reservoir.initRandomSeed = initRandomSeed;
                }
            }
            

            for(uint depth=1; ((depth<(kMaxBounces-1)) || ((depth==(kMaxBounces-1)) && !is_prev_diffuse)) && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
            {
                // -------------------- BSDF Sampling ----------------------
                mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling);
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                pathLength += hitT;
                if(any(throughput > 0.) && hit.isValid() && (pathLength < maxPathLength)){
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    bool is_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;

                    // sample light
                    float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
                    float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
                    float laserT;
                    HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
                    ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
                    let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));

                    if(rcVertexPostBounce == 1){
                        rcVertexPostBounce += 1;
                        rcNextVertexHit = hit;
                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = hitT * hitT;
                        p_brdf *= (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;
                    } else if(rcVertexPostBounce == 2){
                        rcVertexPostBounce += 1;
                        rcNextVertexWi = -bsdfSample.wo;
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    } else if(rcVertexPostBounce > 2) {
                        rcVertexPostBounce += 1;
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    }
                    
                    // perform ellipsoidal connection
                    if(depth < (kMaxBounces - 1)){
                        // sample ellipse
                        HitInfo ellipse_hit;
                        float ellipse_pdfA = 0.0f;
                        float direct_pdfA = 0.0f;
                        float3 ellipse_posW = float3(0.0);
                        float3 ellipse_f_temp = float3(0.0);
                        float3 L_laser_mi = sampleEllipsoidal(sd, laser_sd, mi, laser_mi, 
                            pathLength + laserT, ellipse_hit, ellipse_posW, 
                            ellipse_f_temp, ellipse_pdfA, direct_pdfA,
                            sg);
                        if(ellipse_pdfA > 0.0) L_laser_mi /= ellipse_pdfA;
                        float misWeight = (ellipse_pdfA > 0) ? ellipse_pdfA / (ellipse_pdfA + direct_pdfA) : 0.0;

                        float ellipselaserT = laserT + length(ellipse_posW - laser_sd.posW);
                        if((rcVertexPostBounce == 0) && is_prev_diffuse && is_diffuse){
                            rcVertexBounce = depth;
                            rcVertexPathLength = pathLength;
                            rcVertexPostBounce += 1;
                            rcVertexHit = hit;
                            rcNextVertexHit = ellipse_hit;
                            rcNextVertexWi = normalize(ellipse_posW - laser_sd.posW);
                            float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                            float G12 = hitT * hitT;
                            p_brdf = (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;
                        }
                        // was rcVertexPostBounce == 1
                        else if(rcVertexPostBounce == 2){
                            rcNextVertexWi = normalize(sd.posW - ellipse_posW);
                        }
                        // else if(rcVertexPostBounce == 2){
                        //     rcVertexPostBounce += 1;
                        //     rcNextVertexWi = -bsdfSample.wo;
                        //     postfixThroughput *= bsdfSample.weight;
                        //     postfixPathLength += hitT;
                        // } else if(rcVertexPostBounce > 2) {
                        //     rcVertexPostBounce += 1;
                        //     postfixThroughput *= bsdfSample.weight;
                        //     postfixPathLength += hitT;
                        // }

                        float3 L_mi = mi.eval(sd, normalize(ellipse_posW-sd.posW), sg);
                        float pathLengthWeight = pathLengthImportance(pathLength 
                            + length(sd.posW - ellipse_posW) + ellipselaserT, tcurr, useRoughTimeGate);

                        float3 f = misWeight * throughput * L_mi * L_laser_mi * pathLengthWeight;
                        float3 postfixf = postfixThroughput * L_laser_mi * max(0.0, dot(sd.getOrientedFaceNormal(), normalize(ellipse_posW-sd.posW)));
                        float3 postfixIrradiance = (rcVertexPostBounce == 1) ? ellipse_f_temp : postfixf;
                        float postfixPathLengthFull = (rcVertexPostBounce == 1) ? ellipselaserT : postfixPathLength + length(sd.posW - ellipse_posW) + ellipselaserT;
                        
                        // f = float3(f.x);
                        float3 f_full = f * p_brdf * ((rcVertexPostBounce == 1) ? ellipse_pdfA : 1.0);

                        float weight = luminance(f) * 1.0 / M;

                        if(reservoir.update(f_full, weight, 1, sg))
                        {
                            if(rcVertexPostBounce > 0){
                                reservoir.rcVertexHit = rcVertexHit;
                                reservoir.rcNextVertexHit = rcNextVertexHit;
                                reservoir.rcNextVertexWi = rcNextVertexWi;
                                reservoir.rcNextVertexIrradiance = postfixIrradiance;
                                reservoir.rcNextVertexPathLength = postfixPathLengthFull;
                                reservoir.rcVertexPathLength = rcVertexPathLength;
                                reservoir.rcVertexBounce = rcVertexBounce;
                                reservoir.initRandomSeed = initRandomSeed;
                            } else {
                                reservoir.rcVertexBounce = 0;
                            }
                        }
                    }

                    const uint lobeTypes = mi.getLobeTypes(sd);
                    const bool hasNonDeltaLobes = (lobeTypes & (uint)LobeType::NonDelta) != 0;

                    // perform direct connection if prev was specular
                    if(!is_prev_diffuse && hasNonDeltaLobes){
                        float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
                        float toLaserHitDist = length(laser_sd.posW - sd.posW);
                        bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
                        float3 L_mi = mi.eval(sd, toLaserHitDir, sg);
                        float3 L_laser_mi = laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower * float(V);
                        float pathLengthTotal = pathLength + toLaserHitDist + laserT;

                        float pathLengthWeight = pathLengthImportance(pathLengthTotal, tcurr, useRoughTimeGate);

                        float3 f = throughput * L_mi * L_laser_mi * pathLengthWeight;
                        float3 postfixf = postfixThroughput * L_laser_mi * max(0.0, dot(sd.getOrientedFaceNormal(), toLaserHitDir));
                        float3 postfixIrradiance = postfixf;
                        float postfixPathLengthFull = postfixPathLength + toLaserHitDist + laserT;

                        float3 f_full = f * p_brdf;
                        float weight = luminance(f) * 1.0 / M;
                        if(reservoir.update(f_full, weight, 1, sg))
                        {
                            if(rcVertexPostBounce > 0){
                                reservoir.rcVertexHit = rcVertexHit;
                                reservoir.rcNextVertexHit = rcNextVertexHit;
                                reservoir.rcNextVertexWi = rcNextVertexWi;
                                reservoir.rcNextVertexIrradiance = postfixIrradiance;
                                reservoir.rcNextVertexPathLength = postfixPathLengthFull;
                                reservoir.rcVertexPathLength = rcVertexPathLength;
                                reservoir.rcVertexBounce = rcVertexBounce;
                                reservoir.initRandomSeed = initRandomSeed;
                            } else {
                                reservoir.rcVertexBounce = 0;
                            }
                        }
                    }
                    is_prev_diffuse = is_diffuse;
                }
            }
#endif
// #elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
//             // sample light
//             float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
//             float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
//             float laserT;
//             HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
//             ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
//             let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
            
//             // sample ellipse
//             HitInfo ellipse_hit;
//             float ellipse_pdfA;
//             float3 ellipse_posW;
//             float3 ellipse_f_temp;
//             float3 L_laser_mi = 
//                 sampleEllipsoidal(sd, laser_sd, mi, laser_mi,
//                      pathLength + laserT, ellipse_hit, ellipse_posW, ellipse_f_temp, ellipse_pdfA, sg);
            
//             float3 L_mi = mi.eval(sd, normalize(ellipse_posW-sd.posW), sg);
//             float pathLengthWeight = pathLengthImportance(pathLength 
//                 + length(sd.posW - ellipse_posW) + length(ellipse_posW - laser_sd.posW) + laserT, tcurr, useRoughTimeGate);

//             float3 f_full = throughput * L_mi * L_laser_mi * pathLengthWeight;
//             // f_full = float3(f_full.x);
//             float weight = (ellipse_pdfA == 0.0) ? 0.0 : luminance(f_full) / ellipse_pdfA * 1.0 / M;
            
//             if(reservoir.update(f_full, weight, 1, sg))
//             {
//                 reservoir.rcVertexHit = ellipse_hit;
//                 reservoir.rcNextVertexHit = laserhit;
//                 reservoir.rcNextVertexWi = laser_d;
//                 reservoir.rcNextVertexIrradiance = laserPower;
//                 reservoir.rcNextVertexPathLength = laserT;
//                 reservoir.rcVertexPathLength = pathLength + length(sd.posW - ellipse_posW);
//                 reservoir.rcVertexBounce = 1;
//                 reservoir.initRandomSeed = initRandomSeed;
//             }

//             for(uint depth=1; depth<kMaxBounces - 1 && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
//             {
//                 // -------------------- BSDF Sampling ----------------------
//                 mi.sample(sd, sg, bsdfSample, kUseImportanceSampling);
//                 throughput *= bsdfSample.weight;
//                 bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

//                 hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
//                 pathLength += hitT;

//                 if(any(throughput > 0.) && hit.isValid() && (pathLength < maxPathLength)){
//                     sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
//                     mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

//                     bool is_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;

//                     // sample light
//                     float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
//                     float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
//                     float laserT;
//                     HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
//                     ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
//                     let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));

//                     // sample ellipse
//                     HitInfo ellipse_hit;
//                     float ellipse_pdfA;
//                     float3 ellipse_posW;
//                     float3 ellipse_f_temp;
//                     float3 L_laser_mi = 
//                         sampleEllipsoidal(sd, laser_sd, mi, laser_mi,
//                              pathLength + laserT, ellipse_hit, ellipse_posW, ellipse_f_temp, ellipse_pdfA, sg);
                    
//                     if(ellipse_pdfA > 0.0) L_laser_mi /= ellipse_pdfA;

//                     laserT += length(ellipse_posW - laser_sd.posW);


//                     if(rcVertexPostBounce == 0){
//                         rcVertexBounce = depth;
//                         rcVertexPathLength = pathLength;
//                         rcVertexPostBounce += 1;
//                         rcVertexHit = hit;
//                         rcNextVertexHit = ellipse_hit;
//                         rcNextVertexWi = normalize(ellipse_posW - laser_sd.posW);
//                         float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
//                         float G12 = hitT * hitT;
//                         p_brdf = (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;
//                     }
//                     else if(rcVertexPostBounce == 1){
//                         rcVertexPostBounce += 1;
//                         rcNextVertexHit = hit;
//                         rcNextVertexWi = normalize(sd.posW - ellipse_posW);
//                         float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
//                         float G12 = hitT * hitT;
//                         p_brdf *= (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;
//                     }
//                     else if(rcVertexPostBounce == 2){
//                         rcVertexPostBounce += 1;
//                         rcNextVertexWi = -bsdfSample.wo;
//                         postfixThroughput *= bsdfSample.weight;
//                         postfixPathLength += hitT;
//                     } else if(rcVertexPostBounce > 2) {
//                         rcVertexPostBounce += 1;
//                         postfixThroughput *= bsdfSample.weight;
//                         postfixPathLength += hitT;
//                     }
//                     is_prev_diffuse = is_diffuse;

                    
//                     float3 L_mi = mi.eval(sd, normalize(ellipse_posW-sd.posW), sg);
//                     float pathLengthWeight = pathLengthImportance(pathLength 
//                         + length(sd.posW - ellipse_posW) + laserT, tcurr, useRoughTimeGate);


//                     float3 f = throughput * L_mi * L_laser_mi * pathLengthWeight;
//                     float3 postfixf = postfixThroughput * L_laser_mi * max(0.0, dot(sd.getOrientedFaceNormal(), normalize(ellipse_posW-sd.posW)));
//                     float3 postfixIrradiance = (rcVertexPostBounce == 1) ? ellipse_f_temp : postfixf;
//                     float postfixPathLengthFull = (rcVertexPostBounce == 1) ? laserT : postfixPathLength + length(sd.posW - ellipse_posW)  + laserT;
                    
//                     // f = float3(f.x);
//                     float3 f_full = f * p_brdf * ((rcVertexPostBounce == 1) ? ellipse_pdfA : 1.0);

//                     float weight = luminance(f) * 1.0 / M;

//                     if(reservoir.update(f_full, weight, 1, sg) && rcVertexPostBounce > 0)
//                     {
//                         reservoir.rcVertexHit = rcVertexHit;
//                         reservoir.rcNextVertexHit = rcNextVertexHit;
//                         reservoir.rcNextVertexWi = rcNextVertexWi;
//                         reservoir.rcNextVertexIrradiance = postfixIrradiance;
//                         reservoir.rcNextVertexPathLength = postfixPathLengthFull;
//                         reservoir.rcVertexPathLength = rcVertexPathLength;
//                         reservoir.rcVertexBounce = rcVertexBounce;
//                         reservoir.initRandomSeed = initRandomSeed;
//                     }
//                 }
//             }
// #endif
        }

        float pHat = luminance(reservoir.f);
        reservoir.W = pHat > 0.0 ? 1.0f / pHat * reservoir.wSum : 0.0;

        // refine rough sample?
        // if(useRoughTimeGate){
        //     finetune_reservoir(reservoir, sd0, mi0, d01, sg);
        // }

        // temporal reuse?
        // uint2 prevPixel = uint2(pixel);// + gMotionVector[pixel] * frameDim + (sampleNext2D(sg) * 1.f - 0.f);;

        // if(prevPixel.x >=0 && prevPixel.x <frameDim.x && prevPixel.y >=0 && prevPixel.y <frameDim.y && gFrameCount > 0)
        // {
        //     const HitInfo hit0prev = HitInfo(gTemporalVBuffer[prevPixel]);
        //     if(hit0prev.isValid()){
        //         Ray rayPrev = gScene.camera.computeRayPinholePrevFrame(prevPixel, frameDim);
        //         ShadingData sd0prev = loadShadingData(hit0prev, rayPrev.origin, rayPrev.dir);
        //         IMaterialInstance mi0prev = gScene.materials.getMaterialInstance(sd0prev, ExplicitLodTextureSampler(0.f));
        //         float d01prev = length(rayPrev.origin - sd0prev.posW);

        //         uint linearizedPixelPrev = prevPixel.y * frameDim.x + prevPixel.x;
        //         Reservoir prevReservoir = prevReservoirs[linearizedPixelPrev];
        //         //if(prevReservoir.W > 0){
        //         if(gTemporalHistoryLength > 0){
        //             prevReservoir.M = min(prevReservoir.M, gTemporalHistoryLength * samplesPerPixel);
        //         }
        //         // if(!isValidGeometry(sd0, sd0prev, d01, d01prev)){
        //         //     prevReservoir.M = 0.0;
        //         // }
                
        //         // if (prevReservoir.W == 0.0f && reservoir.W > 0.0f) {
        //         //     // First time we see signal in this bin: reset history
        //         //     prevReservoir.M = 0.0f;
        //         // }
        //             // if(){
        //         //     prevReservoir.M = 0;
        //         // }
        //         // Reservoir dstReservoir = 
        //         // combine_reservoirs_with_shiftmapping(
        //         //     prevReservoir, reservoir,
        //         //     sd0, sd0, mi0, mi0, d01, d01, tprev, tcurr, 
        //         //     prevReservoir.M, sg
        //         // );

        //         Reservoir dstReservoir;

        //         // dstReservoir = combine_reservoirs(reservoir, prevReservoir, sg);

        //         // add prev as curr
        //         combine_reservoir_with_shiftmapping(
        //             dstReservoir,
        //             prevReservoir,
        //             reservoir,
        //             reservoir.M,
        //             sd0prev, mi0prev, d01,
        //             tcurr, tprev,
        //             false, // this is not canonical
        //             sg
        //         );

        //         // add curr as curr
        //         combine_reservoir_with_shiftmapping(
        //             dstReservoir,
        //             reservoir,
        //             prevReservoir,
        //             prevReservoir.M,
        //             sd0, mi0, d01prev,
        //             tprev, tcurr,
        //             true, // this is canonical
        //             sg
        //         );

        //         float pHat = luminance(dstReservoir.f);
        //         dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
        //         reservoir = dstReservoir;
        //         //}
        //     }
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


bool isValidGeometry(const ShadingData sd1, const ShadingData sd2, float d1, float d2){
    const float normalThreshold = 0.7f;
    const float depthThreshold = 0.1f;

    return  dot(sd1.getOrientedFaceNormal(), sd2.getOrientedFaceNormal()) > normalThreshold 
                && abs(d1 - d2) < depthThreshold * d1 && 
                (sd1.materialID == sd2.materialID);
}

float3 evalDirectConnection(const ShadingData sd, const ShadingData laser_sd, const IMaterialInstance mi, const IMaterialInstance laser_mi, float pathLength, inout SampleGenerator sg){
    float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
    float toLaserHitDist = length(laser_sd.posW - sd.posW);
    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
    float3 L = mi.eval(sd, toLaserHitDir, sg) * laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower;
    L *= pathLengthImportance(pathLength + toLaserHitDist, tcurr);
    return L * V;
}

float3 sampleEllipsoidal(
    const ShadingData sd, 
    const ShadingData laser_sd, 
    const IMaterialInstance mi, 
    const IMaterialInstance laser_mi, 
    float pathLength, 
    out HitInfo hit,
    out float3 hitPosW,
    out float3 f_temp,
    out float pdf,
    out float directpdfA,
    inout SampleGenerator sg){

    hit = {};
    hitPosW = {};
    f_temp = {};
    pdf = 0.0f;
    directpdfA = 0.0f;

    float ttarget = tcurr - pathLength;
    
    Ellipsoid E;
    float tSampled;
    float pdfT;
    
    samplePathLength(ttarget, sampleNext1D(sg), tSampled, pdfT, time_gate_window_rough > 0.0f);

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

    // uint indices[kMaxCandidates];
    // uint triangleCount = 0;
    // emissiveSampler.findAllTrianglesEllipsoid(E, triangleCount, indices);
    // if(triangleCount == 0){
    //     return float3(0.0f);
    // }
    // triangleIndex = indices[uint(triangleCount * sampleNext1D(sg))];
    // EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);
    // trianglePdf = 1.f / (float)triangleCount;
    
    // check if sd or laser_sd is on triangle --> no need to check
    if(abs(dot(tri.normal, normalize(tri.posW[0] - sd.posW))) < 1e-4 
        || abs(dot(tri.normal, normalize(tri.posW[0] - laser_sd.posW))) < 1e-4){
        return float3(0.0);
    }

    // ellipsoid-triangle intersection
    SampleResultArea result = sampleOnTriangleEllipsoid(
        E,
        tri.posW[0], tri.posW[1], tri.posW[2],
        sampleNext1D(sg), sampleNext1D(sg));
    
    // valid result
    if(result.ok){
        // pathLength = pathLength + length(sd.posW - result.p) + length(result.p - laser_sd.posW);

        // shoot ray to sampled point
        float hitT;
        hit = traceRay(laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW), hitT);
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

            // float3 f1 = mi.eval(sd, v12, sg);
            float3 f2 = mi2.eval(second_sd, -v12, sg);
            float3 f3 = laser_mi.eval(laser_sd, v32, sg);
            float n23 = max(dot(n2, -v32), 0.0);
            float G12 = dot(l12, l12);
            float G23 = dot(l32, l32);
            if(G12 < 1e-9 || G23 < 1e-9) return float3(0.0);

            float3 f = f2 * f3 * n23 / (G12 * G23) * laserPower;
            f_temp = f3 / G23 * n23 * laserPower;

            float pdfA = trianglePdf * result.pdfA * pdfT;
            if(pdfA < 1e-9) return float3(0.0);

            pdf = pdfA;
            hitPosW = p2;

            float directpdf = mi.evalPdf(sd, normalize(second_sd.posW - sd.posW));
            float n21 = abs(dot(n2, -v12));
            directpdfA = (G12 < 1e-9) ? 0.0 : n21 / G12;

            // f = f / max(pdfA, 1e-4f);
            bool V = traceVisibilityRay(sd.computeRayOrigin(), v12, d12);

            return f * V;
        }
    }
    return float3(0.0);
}

// float3 evalEllipsoidalConnection(const ShadingData sd, const ShadingData laser_sd, const IMaterialInstance mi, const IMaterialInstance laser_mi, 
//         float pathLength, inout SampleGenerator sg, inout LightSample lightSample, out float pdf){
//     float ttarget = tcurr - pathLength;
    
//     Ellipsoid E;
//     float tSampled;
//     float pdfT;
    
//     samplePathLength(ttarget, sampleNext1D(sg), tSampled, pdfT);

//     // build Ellipsoid and check if valid;
//     if(!buildEllipsoidFromFoci(
//         sd.posW, laser_sd.posW, tSampled,
//         sd.getOrientedFaceNormal(), laser_sd.getOrientedFaceNormal(), E))
//     {
//         return float3(0.0);
//     }

//     uint triangleIndex;
//     float trianglePdf;

//     // randomly select triangle
//     if(!emissiveSampler.sampleTriangleEllipsoid(
//         E, sg, triangleIndex, trianglePdf)){
//         return float3(0.0);
//     }

//     const EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);

//     // check if sd or laser_sd is on triangle --> no need to check
//     if(abs(dot(tri.normal, normalize(tri.posW[0] - sd.posW))) < 1e-5 
//     || abs(dot(tri.normal, normalize(tri.posW[0] - laser_sd.posW))) < 1e-5){
//         return float3(0.0);
//     }

//     // ellipsoid-triangle intersection
//     SampleResultArea result = sampleOnTriangleEllipsoid(
//         E,
//         tri.posW[0], tri.posW[1], tri.posW[2],
//         sampleNext1D(sg), sampleNext1D(sg));

//     // valid result
//     if(result.ok){
//         pathLength = pathLength + length(sd.posW - result.p) + length(result.p - laser_sd.posW);

//         // shoot ray to sampled point
//         float hitT;
//         HitInfo hit = traceRay(laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW), hitT);
//         ShadingData second_sd = loadShadingData(hit, laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW));

//         // valid point?
//         if(hitT > 0 && hit.isValid()
//             && abs(dot(second_sd.getOrientedFaceNormal(), tri.normal)) > 0.999 
//             && abs(hitT - length(laser_sd.posW - result.p)) < 1e-3){
            
//             let mi2 = gScene.materials.getMaterialInstance(second_sd, ExplicitLodTextureSampler(0));

//             const float3 p1 = sd.posW;
//             const float3 p2 = second_sd.posW;
//             const float3 p3 = laser_sd.posW;

//             const float3 n2 = second_sd.getOrientedFaceNormal();
//             const float3 l12 = p2 - p1;
//             const float3 l32 = p2 - p3;

//             const float3 v12 = normalize(l12);
//             const float3 v32 = normalize(l32);
//             const float d12 = length(p2 - p1);
//             const float d32 = length(p2 - p3);

//             float3 f1 = mi.eval(sd, v12, sg);
//             float3 f2 = mi2.eval(second_sd, -v12, sg);
//             float3 f3 = laser_mi.eval(laser_sd, v32, sg);
//             float n23 = max(dot(n2, -v32), 0.0);
//             float G12 = dot(l12, l12);
//             float G23 = dot(l32, l32);
//             float3 f = f1 * f2 * f3 * n23 / (G12 * G23) * laserPower;
//             float pdfA = trianglePdf * result.pdfA * pdfT;
//             // f = f / max(pdfA, 1e-4f);

//             bool V = traceVisibilityRay(sd.computeRayOrigin(), v12, d12);
//             // lightSample.p = p2;
//             // lightSample.n = n2;
//             lightSample.hit = hit;
//             pdf = pdfA;
            
//             return f * V;
//         }
//     }
//     return float3(0.0);
// }


[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
    // color = float3(color.x, color.x, color.x);
    // gOutputColor[pixel] = float4(color / min(1.0, time_gate_window), 1.f);
}
