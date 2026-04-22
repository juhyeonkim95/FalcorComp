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
RWStructuredBuffer<Reservoir> tempReservoirs;
RWStructuredBuffer<Reservoir> currReservoirs;

// Outputs
RWTexture2D<float4> gOutputColor;

#if USE_SINGLE_CHANNEL
RWTexture3D<float> gTransientHistogram;
#else
RWTexture3D<float4> gTransientHistogram;
#endif

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
        HitInfo rcVertexHit;
        float3 rcVertexWi;

        uint M = samplesPerPixel;

        float maxPathLength = tmax;
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);


        // finalize current reservoirs
        for(int j=0; j<tbin; j++){
            uint linearizedHistPixel = linearizedPixel * tbin + j;
            currReservoirs[linearizedHistPixel].wSum = 0.0;
            currReservoirs[linearizedHistPixel].W = 0.0;
            currReservoirs[linearizedHistPixel].f = 0.0;
        }


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
            float p_brdf = 1.0;
            
            bool is_prev_diffuse = bsdfProperties0.roughness > specularRoughnessThreshold;
            uint rcVertexPostBounce = 0;
            uint rcVertexBounce = 0;
            
            uint initRandomSeed = sg_mi_sample.getCurrentSeed();
            uint rcNextVertexRandomSeed;

            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
            {
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg_mi_sample, bsdfSample, kUseImportanceSampling)) {break;}
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
                    //  && hitT > RECONNECTION_DISTANCE_THRESHOLD
                    if(rcVertexPostBounce == 0 && is_curr_diffuse && is_prev_diffuse){
                        rcVertexBounce = depth;
                        rcVertexHit = hit;
                        float n21 = abs(dot(sd.faceN, sd.V));
                        if(n21 < 1e-6){n21 = 0.0;}
                        float G12 = max(hitT * hitT, kMinLightDistSqr);
                        p_brdf = bsdfSample.pdf * n21 / G12;
                    }
                    // previous one was rcVertex
                    else if(rcVertexPostBounce == 1){
                        rcVertexWi = -bsdfSample.wo;
                        postfixThroughput *= bsdfSample.weight;
                        postfixPathLength += hitT;
                    }
                    // more than two bounce after rcVertex
                    else if(rcVertexPostBounce > 1) {
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
                    float3 f = throughput * L_mi * L_light;
                    
                    float3 f_full = f * p_brdf;

                    float weight = p_brdf == 0.0 ? 0.0 : getReservoirWeight(f) * 1.0 / M;

                    uint pathLengthIdx;
                    float pathLengthIdxResidual;
                    if(getPathLengthIndex(totalPathLength, pathLengthIdx, pathLengthIdxResidual)){
                        uint reservoir_idx = linearizedPixel * tbin + pathLengthIdx;
                        uint reservoir_idx2 = clamp(reservoir_idx + 1, 0, tbin-1);
                        ///////////////////////////////////////////////////////////////
                        // Case 1. we have RC Vertex --> need to update reservoir info
                        ///////////////////////////////////////////////////////////////
                        if(rcVertexBounce > 0){
                            if(rcVertexPostBounce == 0){
                                rcVertexWi = normalize(sd.posW - ls.posW());
                            }
                            float nDotL = dot(sd.getOrientedFaceNormal(), toLightDir);
                            if(nDotL < 1e-6){
                                nDotL = 0.0;
                            }
                            float3 postfixIrradinace = postfixThroughput * L_light * nDotL;
                            float postfixPathLengthFull = postfixPathLength + toLightDist + ls.laserT;

                            if(currReservoirs[reservoir_idx].update(f_full, weight, 1, sg)){
                                currReservoirs[reservoir_idx].rcVertexHit = rcVertexHit;
                                currReservoirs[reservoir_idx].rcVertexWi = rcVertexWi;
                                currReservoirs[reservoir_idx].rcVertexPostPathLength = postfixPathLengthFull;
                                #if USE_SINGLE_CHANNEL
                                currReservoirs[reservoir_idx].rcVertexPostIrradiance = getReservoirWeight(postfixIrradinace);
                                #else
                                currReservoirs[reservoir_idx].rcVertexPostIrradiance = postfixIrradinace;
                                #endif
                                currReservoirs[reservoir_idx].rcVertexBounce = rcVertexBounce;
                                currReservoirs[reservoir_idx].initRandomSeed = initRandomSeed;
                            }
                            // if(currReservoirs[reservoir_idx].update(f_full, weight * (1.0 - pathLengthIdxResidual), 1, sg)){
                            //     currReservoirs[reservoir_idx].rcVertexHit = rcVertexHit;
                            //     currReservoirs[reservoir_idx].rcVertexWi = rcVertexWi;
                            //     currReservoirs[reservoir_idx].rcVertexPostPathLength = postfixPathLengthFull;
                            //     #if USE_SINGLE_CHANNEL
                            //     currReservoirs[reservoir_idx].rcVertexPostIrradiance = getReservoirWeight(postfixIrradinace);
                            //     #else
                            //     currReservoirs[reservoir_idx].rcVertexPostIrradiance = postfixIrradinace;
                            //     #endif
                            //     currReservoirs[reservoir_idx].rcVertexBounce = rcVertexBounce;
                            //     currReservoirs[reservoir_idx].initRandomSeed = initRandomSeed;
                            // }
                            // if(currReservoirs[reservoir_idx2].update(f_full, weight * pathLengthIdxResidual, 1, sg)){
                            //     currReservoirs[reservoir_idx2].rcVertexHit = rcVertexHit;
                            //     currReservoirs[reservoir_idx2].rcVertexWi = rcVertexWi;
                            //     currReservoirs[reservoir_idx2].rcVertexPostPathLength = postfixPathLengthFull;
                            //     #if USE_SINGLE_CHANNEL
                            //     currReservoirs[reservoir_idx2].rcVertexPostIrradiance = getReservoirWeight(postfixIrradinace);
                            //     #else
                            //     currReservoirs[reservoir_idx2].rcVertexPostIrradiance = postfixIrradinace;
                            //     #endif
                            //     currReservoirs[reservoir_idx2].rcVertexBounce = rcVertexBounce;
                            //     currReservoirs[reservoir_idx2].initRandomSeed = initRandomSeed;
                            // }
                            
                        } else {
                            if(currReservoirs[reservoir_idx].update(f, weight, 1, sg))
                            {
                                currReservoirs[reservoir_idx].rcVertexBounce = 0;
                            }
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

        // finalize current reservoirs
        for(int j=0; j<tbin; j++){
            uint linearizedHistPixel = linearizedPixel * tbin + j;
            float pHat = getReservoirWeight(currReservoirs[linearizedHistPixel].f);
            currReservoirs[linearizedHistPixel].M = samplesPerPixel;
            currReservoirs[linearizedHistPixel].W = pHat > 0 ? 1.0f / pHat * currReservoirs[linearizedHistPixel].wSum : 0.0;
        }


        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        // Temporal Reuse
        /////////////////////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////////////////////////////////////////////////////
        
        uint2 prevPixel = uint2(pixel);// + gMotionVector[pixel] * frameDim + (sampleNext2D(sg) * 1.f - 0.f);
        bool isPrevPixelValid = (prevPixel.x >=0) && (prevPixel.x < frameDim.x) && (prevPixel.y >=0) && (prevPixel.y < frameDim.y);
        {
            // (2) splatting
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

                    // iterate over each time bin
                    for(int j=0; j<tbin; j++){
                        uint linearizedHistPixelPrev = linearizedPixelPrev * tbin + j;
                        Reservoir prevReservoir = prevReservoirs[linearizedHistPixelPrev];

                        VertexData prev_x2 = gScene.getVertexData(prevReservoir.rcVertexHit.getTriangleHit());
                        float newPathLength = d01 + length(sd0.posW - prev_x2.posW) + prevReservoir.rcVertexPostPathLength;
                        
                        uint pathLengthIdx = j;
                        float pathLengthIdxResidual;
                        // if(getPathLengthIndex(newPathLength, pathLengthIdx, pathLengthIdxResidual))
                        {
                            float M_temp = prevReservoir.M;
                            if(!isValidGeometry(sd0, sd0prev, d01, d01prev)){
                                M_temp = 0.0;
                            }
                            if(gTemporalHistoryLength > 0){
                                M_temp = min(M_temp, gTemporalHistoryLength * samplesPerPixel);
                            }
                            {
                                uint linearizedHistPixelCurr = linearizedPixel * tbin + pathLengthIdx;
                            
                                Reservoir currReservoir = currReservoirs[linearizedHistPixelCurr];
                            
                                Reservoir dstReservoir;// = combine_reservoirs(prevReservoir, currReservoir, sg);

                                prevReservoir.M = M_temp;// * (1.0 - pathLengthIdxResidual);

                                combine_reservoir_with_shiftmapping(
                                    dstReservoir,
                                    prevReservoir,
                                    currReservoir.M,
                                    sd0, mi0, d01,
                                    false, pathLengthIdx,
                                    false,
                                    sg
                                );

                                combine_reservoir_with_shiftmapping(
                                    dstReservoir,
                                    currReservoir,
                                    prevReservoir.M,
                                    sd0prev, mi0prev, d01prev,
                                    false, j,
                                    true,
                                    sg
                                );

                                float pHat = getReservoirWeight(dstReservoir.f);
                                dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
                                currReservoirs[linearizedHistPixelCurr] = dstReservoir;
                            }

                            // pathLengthIdx = clamp(pathLengthIdx + 1, 0, tbin - 1);
                            // {
                            //     uint linearizedHistPixelCurr = linearizedPixel * tbin + pathLengthIdx;
                            
                            //     Reservoir currReservoir = currReservoirs[linearizedHistPixelCurr];
                            
                            //     Reservoir dstReservoir;// = combine_reservoirs(prevReservoir, currReservoir, sg);

                            //     prevReservoir.M = M_temp * (pathLengthIdxResidual);

                            //     if(!isValidGeometry(sd0, sd0prev, d01, d01prev)){
                            //         prevReservoir.M = 0.0;
                            //     }

                            //     combine_reservoir_with_shiftmapping(
                            //         dstReservoir,
                            //         prevReservoir,
                            //         currReservoir.M,
                            //         sd0, mi0, d01,
                            //         false, pathLengthIdx,
                            //         false,
                            //         sg
                            //     );

                            //     combine_reservoir_with_shiftmapping(
                            //         dstReservoir,
                            //         currReservoir,
                            //         prevReservoir.M,
                            //         sd0prev, mi0prev, d01prev,
                            //         false, j,
                            //         true,
                            //         sg
                            //     );

                            //     float pHat = getReservoirWeight(dstReservoir.f);
                            //     dstReservoir.W = pHat > 0 ? 1.0f / pHat * dstReservoir.wSum : 0.0;
                            //     currReservoirs[linearizedHistPixelCurr] = dstReservoir;
                            // }
                            
                        }
                    }
                }
            }
        }
        
        // evaluate
        for(int j=0; j<tbin; j++){
            uint linearizedHistPixel = linearizedPixel * tbin + j;
            float3 L = currReservoirs[linearizedHistPixel].W * currReservoirs[linearizedHistPixel].f;
            L /= tunit;
            #if USE_SINGLE_CHANNEL //currReservoirs[linearizedHistPixel].dummy.x;//
            gTransientHistogram[uint3(pixel.x, pixel.y, j)] += getReservoirWeight(L);
            #else
            gTransientHistogram[uint3(pixel.x, pixel.y, j)] += float4(L, 1.0);
            #endif
        }
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
    gOutputColor[pixel] = float4(color, 1.f);
}