#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
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
static const float RECONNECTION_DISTANCE_THRESHOLD = 1e-3;


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

// float3 getVelocity(HitInfo hit)
// {   
//     if(!hit.isValid()){
//         return float3(0,0,0);
//     }
//     TriangleHit triHit = hit.getTriangleHit();
//     float faceAreaW = gScene.getFaceAreaW(triHit.instanceID, triHit.primitiveIndex);
//     if(faceAreaW < 0.5){
//         return float3(0, 0, 1);
//     } else {
//         return float3(0, 0, 0);
//     }
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
        float v01 = dot((getVelocity(hit0)), primaryRayDir);

        //
        // Laser Hit Material
        //
        Reservoir reservoir = Reservoir();

        HitInfo rcVertexHit;
        HitInfo rcNextVertexHit;
        float3 rcNextVertexWi;

        uint M = useRoughTimeGate ? uint(samplesPerPixel * (1.0-gRoughTimeGateSampleRatio)) : samplesPerPixel;

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
            
            float pathVelocity = 0.0;
            float3 prevVelocity = 0.0;

            pathVelocity += dot((getVelocity(hit0) - prevVelocity), primaryRayDir);
            prevVelocity = getVelocity(hit0);

            BSDFSample bsdfSample;

            HitInfo hit = hit0;
            float hitT;
            float p_brdf;
            
            bool is_prev_diffuse = bsdfProperties0.roughness > specularRoughnessThreshold;
            uint rcVertexPostBounce = 0;
            uint rcVertexBounce = 0;
            
            uint initRandomSeed = sg_mi_sample.getCurrentSeed();
            uint rcNextVertexRandomSeed;

            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && hit.isValid(); depth++)
            {
                // -------------------- BSDF Sampling ----------------------
                uint rcNextVertexRandomSeedTemp = sg_mi_sample.getCurrentSeed();
                if(!mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);

                if(any(throughput > 0.) && hit.isValid()){
                    // keep info
                    float3 prev_sd_posW = sd.posW;
                    
                    // Update new Hit Point
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    bool is_curr_diffuse = mi.getProperties(sd).roughness > specularRoughnessThreshold;

                    // need to re-calculate hitT
                    hitT = length(sd.posW - prev_sd_posW);
                    pathLength += hitT;
                    
                    // float hitV = dot((getVelocity(hit) - prevVelocity), bsdfSample.wo);
                    // pathVelocity += hitV;
                    // prevVelocity = getVelocity(hit);
                    float hitV = dot((getVelocity(hit) - prevVelocity), bsdfSample.wo);
                    pathVelocity += hitV;
                    prevVelocity = getVelocity(hit);

                    //////////////////////////////
                    // RC Vertex Check
                    //////////////////////////////

                    // is this new rcVertex?
                    if(rcVertexPostBounce == 0 && is_curr_diffuse && is_prev_diffuse){
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
                        postfixPathLength += hitV;
                    }
                    // more than two bounce after rcVertex
                    else if(rcVertexPostBounce > 2) {
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitV;
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

                    float toLightVelocity = dot((getVelocity(HitInfo()) - prevVelocity), toLightDir);
                    float toLightVelocity2 = dot((float3(0.0) - getVelocity(HitInfo())), -ls.dir);

                    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDist);
                    float3 L_mi = mi.eval(sd, toLightDir, sg);
                    float3 L_light = ls.evalLi(sd.posW, sg) * float(V);
                    float totalPathLength = pathVelocity + toLightVelocity + toLightVelocity2;

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
                        float postfixPathLengthFull = (rcVertexPostBounce == 0) ? toLightVelocity2 : postfixPathLength + toLightVelocity + toLightVelocity2;
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

        }
        // finalize current reservoir
        float pHat = luminance(reservoir.f);
        reservoir.W = pHat > 0 ? 1.0f / pHat * reservoir.wSum : 0.0;
        
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        // Temporal Reuse
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        // if(gFrameCount > 0)
        // {
        //     // generate previous camera ray
        //     Ray rayPrev = gScene.camera.computeRayPinholePrevFrame(pixel, frameDim);
        //     uint linearizedPixelPrev = pixel.y * frameDim.x + pixel.x;
        //     Reservoir prevReservoir = prevReservoirs[linearizedPixelPrev];

        //     // M capping
        //     if(gTemporalHistoryLength > 0){
        //         prevReservoir.M = min(prevReservoir.M, gTemporalHistoryLength * samplesPerPixel);
        //     }
            
        //     Reservoir dstReservoir;

        //     // (1) prev as curr
        //     combine_reservoir_with_shiftmapping(
        //         dstReservoir,
        //         prevReservoir,
        //         reservoir.M,
        //         sd0, mi0, v01,
        //         tcurr, tprev,
        //         1.0,
        //         false, // this is not canonical
        //         laserOrigin,
        //         laserDirection,
        //         sg
        //     );
        //     // (2) curr as curr
        //     combine_reservoir_with_shiftmapping(
        //         dstReservoir,
        //         reservoir,
        //         prevReservoir.M,
        //         sd0, mi0, v01,
        //         tprev, tcurr,
        //         1.0,
        //         true, // this is canonical
        //         laserPrevOrigin,
        //         laserPrevDirection,
        //         sg
        //     );
        //     float pHat = luminance(dstReservoir.f);
        //     dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
        //     reservoir = dstReservoir;
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





[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
    gOutputColor[pixel] = float4(color / time_gate_window, 1.f);
}