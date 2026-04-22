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
        float3 laser_normal = laserDirection;
        float3 laser_bitangent = perp_stark_onb(laser_normal);
        float3 laser_tangent = cross(laser_bitangent, laser_normal);
        
        // show laser spot?
        // if(kComputeDirect)
        {
            float3 toLaserDir = normalize(laserOrigin - sd0.posW);
            float toLaserDist = length(laserOrigin - sd0.posW);
            bool V = traceVisibilityRay(sd0.computeRayOrigin(), toLaserDir, toLaserDist);
            float minCosAngle = min(laserCosAngle, 1.0-(1e-5));
            bool inspot = (dot(-toLaserDir, laser_normal) > minCosAngle);
            float3 L = mi0.eval(sd0, toLaserDir, sg) * laserPower / (toLaserDist * toLaserDist) * float(inspot);
            L = float3(L.x, 0.0, 0.0);
            outColor += samplesPerPixel * L;
        }
        
        
        // float solidAngle = (float)M_2PI * (1.f - light.cosSubtendedAngle);
        // ls.Li = laserPower / solidAngle;
        // ls.pdf = 
        // float light_pdf_omega = 1.f / solidAngle;

        // const HitInfo laserhit = HitInfo(gLaserVBuffer[uint2(0,0)]);
        // const float4 laserViewW = gLaserViewW[uint2(0,0)];
        // const float laserT = laserViewW.w;
        // ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laserDirection);
        // let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));

        float maxPathLength = getMaxpathLength(tcurr);
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
            if(kComputeDirect){
                float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
                float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
                float laserT;
                HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
                ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
                let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
                
                result += throughput * evalDirectConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, sg);
            }
#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid() && pathLength < maxPathLength; depth++){
                // -------------------- BSDF Sampling ----------------------
                mi.sample(sd, sg, bsdfSample, kUseImportanceSampling);
                throughput *= bsdfSample.weight;
                
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                pathLength += hitT;

                if(hit.isValid() && (pathLength < maxPathLength) && any(throughput > 0.) && !any(throughput < 0.)){
                    float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
                    float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
                    float laserT;
                    HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
                    ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
                    let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));
                    
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    result += throughput * evalDirectConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, sg);
                }
            }
#elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
            ///////////////////////////////////////////////////////////////
            // (0) Sample Light
            ///////////////////////////////////////////////////////////////
            float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
            float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
            float laserT;
            HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
            ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
            let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));

            const uint lobeTypes = mi.getLobeTypes(sd);
            const bool hasNonDeltaLobes = (lobeTypes & (uint)LobeType::NonDelta) != 0;
            bool is_curr_diffuse = bsdfProperties0.roughness > specularRoughnessThreshold;

            ///////////////////////////////////////////////////////////////
            // (1) Perform ellipsoidal 
            ///////////////////////////////////////////////////////////////
#if USE_ELLIPSOIDAL_DIRECT_MIS
            if(hasNonDeltaLobes){
                float ellipsePdfA = 0.0;
                float directPdfA = 0.0;
                float3 L = evalEllipsoidalConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, 
                    ellipsePdfA, directPdfA, sg);
                float misWeight = (ellipsePdfA > 0) ? ellipsePdfA / (ellipsePdfA + directPdfA) : 0.0;
                result += throughput * misWeight * L;
            }
#else 
            if(is_curr_diffuse){
                float ellipsePdfA = 0.0;
                float directPdfA = 0.0;
                float3 L = evalEllipsoidalConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, 
                    ellipsePdfA, directPdfA, sg);
                result += throughput * L;
            }
#endif

            bool is_prev_diffuse = is_curr_diffuse;
#if USE_ELLIPSOIDAL_DIRECT_MIS
            for(uint depth=1; depth < kMaxBounces && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
#else 
            for(uint depth=1; ((depth<(kMaxBounces-1)) || ((depth==(kMaxBounces-1)) && !is_prev_diffuse)) && any(throughput > 0.) && hit.isValid() && pathLength < maxPathLength; depth++)
#endif
            {
                // -------------------- BSDF Sampling ----------------------
                mi.sample(sd, sg, bsdfSample, kUseImportanceSampling);
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                pathLength += hitT;
                if(hit.isValid() && (pathLength < maxPathLength) && any(throughput > 0.)){
                    // keep info
                    float3 prev_sd_posW = sd.posW;
                    float3 prev_sd_N = sd.getOrientedFaceNormal();

                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    BSDFProperties bsdfProperties = mi.getProperties(sd);
                    bool is_curr_diffuse = bsdfProperties.roughness > specularRoughnessThreshold;

                    const uint lobeTypes = mi.getLobeTypes(sd);
                    const bool hasNonDeltaLobes = (lobeTypes & (uint)LobeType::NonDelta) != 0;

                    ///////////////////////////////////////////////////////////////
                    // (0) Sample Light
                    ///////////////////////////////////////////////////////////////
                    float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
                    float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
                    float laserT;
                    HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
                    ShadingData laser_sd = loadShadingData(laserhit, laserOrigin, laser_d);
                    let laser_mi = gScene.materials.getMaterialInstance(laser_sd, ExplicitLodTextureSampler(0.f));

#if USE_ELLIPSOIDAL_DIRECT_MIS
                    ///////////////////////////////////////////////////////////////
                    // (1) Perform ellipsoidal (only if we have left path bounce)
                    ///////////////////////////////////////////////////////////////
                    if((depth < (kMaxBounces - 1)) && hasNonDeltaLobes)
                    {
                        float ellipsePdfA = 0.0;
                        float directPdfA = 0.0;
                        float3 L = evalEllipsoidalConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, 
                            ellipsePdfA, directPdfA, sg);
                        float misWeight = (ellipsePdfA > 0) ? ellipsePdfA / (ellipsePdfA + directPdfA) : 0.0;
                        result += throughput * misWeight * L;
                    }
                    ///////////////////////////////////////////////////////////////
                    // (2) Perform direct
                    ///////////////////////////////////////////////////////////////
                    if(hasNonDeltaLobes){
                        // apply MIS
                        // (1) Direct
                        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
                        float G12 = hitT * hitT;
                        float directPdfA = (G12 < 1e-9) ? 0.0 : bsdfSample.pdf * n21 / G12;

                        // (2) Ellipsoid
                        Ellipsoid E;
                        float ellipseLength = length(sd.posW - prev_sd_posW) + length(sd.posW - laser_sd.posW);
                        float ellipsePdfA = 0.0;
                        if(buildEllipsoidFromFoci(prev_sd_posW, laser_sd.posW, ellipseLength,
                            prev_sd_N, laser_sd.getOrientedFaceNormal(), E))
                        {
                            ellipsePdfA = evalEllipsoidPdf(E, hit, sd, pathLength + laserT - hitT);
                        };
                        float misWeight = directPdfA > 0 ? directPdfA / (ellipsePdfA + directPdfA) : 0.0;

                        float3 L = evalDirectConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, sg);
                        result += throughput * misWeight * L;
                    }
#else
                    ///////////////////////////////////////////////////////////////
                    // (1) Perform ellipsoidal (only if we have left path bounce and current is diffuse)
                    ///////////////////////////////////////////////////////////////
                    if((depth < (kMaxBounces - 1)) && is_curr_diffuse){
                        float ellipsePdfA = 0.0;
                        float directPdfA = 0.0;
                        float3 L = evalEllipsoidalConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, 
                            ellipsePdfA, directPdfA, sg);
                        result += throughput * L;
                    }
                    ///////////////////////////////////////////////////////////////
                    // (2) Perform direct if we did not perform ellipsoidal for previous vertex
                    ///////////////////////////////////////////////////////////////
                    if(!is_prev_diffuse && hasNonDeltaLobes){
                        float3 L = evalDirectConnection(sd, laser_sd, mi, laser_mi, pathLength + laserT, sg);
                        result += throughput * L;
                    }
#endif
                    
                    is_prev_diffuse = is_curr_diffuse;
                }
            }
#endif
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

float3 evalDirectConnection(const ShadingData sd, const ShadingData laser_sd, const IMaterialInstance mi, const IMaterialInstance laser_mi, float pathLength, inout SampleGenerator sg){
    float3 toLaserHitDir = normalize(laser_sd.posW - sd.posW);
    float toLaserHitDist = length(laser_sd.posW - sd.posW);
    if(toLaserHitDist < 1e-4){
        return float3(0.0);
    }
    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLaserHitDir, toLaserHitDist);
    float3 L = mi.eval(sd, toLaserHitDir, sg) * laser_mi.eval(laser_sd, -toLaserHitDir, sg) / (toLaserHitDist * toLaserHitDist) * laserPower;
    L *= pathLengthImportance(pathLength + toLaserHitDist, tcurr);
    return L * V;
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

float3 evalEllipsoidalConnection(
    const ShadingData sd, const ShadingData laser_sd, const IMaterialInstance mi,
    const IMaterialInstance laser_mi, float pathLength, out float ellipsePdfA, out float directPdfA, inout SampleGenerator sg
){
    float ttarget = tcurr - pathLength;
    ellipsePdfA = 0.0;
    directPdfA = 0.0;
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

    // EmissiveTriangle tri;
    // bool success = false;
    // // randomly select triangle
    // for(int j=1; j<20; j++){
    //     if(!emissiveSampler.sampleTriangleEllipsoid(
    //         E, sg, triangleIndex, trianglePdf)){
    //         continue;
    //     }
    //     tri = gScene.triCollection.getTriangle(triangleIndex);
    //     if(!isTriangleValid(E, tri.posW[0], tri.posW[1], tri.posW[2], tri.normal))
    //     {
    //         continue;
    //     }
    //     trianglePdf /= j;
    //     success = true;
    //     break;
    // }
    // if(!success){
    //     return float3(0.0);
    // }
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
    if(result.ok && !isinf(result.pdfA) && !isnan(result.pdfA)){
        pathLength = pathLength + length(sd.posW - result.p) + length(result.p - laser_sd.posW);

        // shoot ray to sampled point
        float hitT;
        HitInfo hit = traceRay(laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW), hitT);
        ShadingData second_sd = loadShadingData(hit, laser_sd.computeRayOrigin(), normalize(result.p - laser_sd.posW));

        // TriangleHit triangleHit = hit.getTriangleHit();
        // uint actualTriangleIndex = gScene.triCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);

        // valid point?
        if(hitT > 0 && hit.isValid()
            && abs(dot(second_sd.getOrientedFaceNormal(), tri.normal)) > 0.999 
            && abs(hitT - length(laser_sd.posW - result.p)) < 1e-3){
            
            let mi2 = gScene.materials.getMaterialInstance(second_sd, ExplicitLodTextureSampler(0));

            
            // float directPdfA = mi.evalPdf(sd, normalize(ellipseP - sd.posW));

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
            float n23 = abs(dot(n2, -v32));
            float G12 = dot(l12, l12);
            float G23 = dot(l32, l32);
            if(G12 < 1e-9 || G23 < 1e-9) return float3(0.0);

            float3 f = f1 * f2 * f3 * n23 / (G12 * G23) * laserPower;
            float pdfA = trianglePdf * result.pdfA * pdfT;
            if(pdfA < 1e-9) return float3(0.0);
            f = f / pdfA; //max(, 1e-4f);
            // f /= pdfA;
            ellipsePdfA = pdfA;
            
            float directpdf = mi.evalPdf(sd, normalize(second_sd.posW - sd.posW));
            float n21 = abs(dot(n2, -v12));
            directPdfA = (G12 < 1e-9) ? 0.0 : directpdf * n21 / G12;

            // outP = p2;

            bool V = traceVisibilityRay(sd.computeRayOrigin(), v12, d12);

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
#if USE_SINGLE_CHANNEL
    color = float3(color.x, color.x, color.x);
#endif
    gOutputColor[pixel] = float4(color / min(1.0, time_gate_window), 1.f);
}
