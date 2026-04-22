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

/** Describes a light sample.
*/

struct IntermediateLightSample
{
    float laserT;
#if IS_LIGHT_SOURCE_LASER
    ShadingData sd;
    IMaterialInstance mi;
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = sd.posW - posW;
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        return laserPower * mi.eval(sd, normalize(posW - sd.posW), sg) / distSqr;
    }
    float3 posW(){
        return sd.posW;
    }
    float3 getOrientedFaceNormal(){
        return sd.getOrientedFaceNormal();
    }
#else
    float3 evalLi(float3 posW, inout SampleGenerator sg){
        float3 toLight = laserOrigin - posW;
        float distSqr = max(dot(toLight, toLight), kMinLightDistSqr);
        return laserPower / distSqr;
    }
    float3 posW(){
        return laserOrigin;
    }
    float3 getOrientedFaceNormal(){
        return laserDirection;
    }
#endif
}

void generateIntermediateLightSample(
    inout SampleGenerator sg, 
    out IntermediateLightSample ils
)
{
#if IS_LIGHT_SOURCE_LASER
    // (1) Collimated laser 
    float3 laser_normal = laserDirection;
    float3 laser_bitangent = perp_stark_onb(laser_normal);
    float3 laser_tangent = cross(laser_bitangent, laser_normal);

    float3 local = sample_cone(sampleNext2D(sg), laserCosAngle);
    float3 laser_d = normalize(laser_tangent*local.x + laser_bitangent*local.y + laser_normal*local.z);
    float laserT;
    HitInfo laserhit = traceRay(laserOrigin, laser_d, laserT);
    ils.sd = loadShadingData(laserhit, laserOrigin, laser_d);
    ils.mi = gScene.materials.getMaterialInstance(ils.sd, ExplicitLodTextureSampler(0.f));
    ils.laserT = laserT;
#else
    // (2) Point Light laser
    ils.laserT = 0.0;
#endif
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
        // if(kComputeDirect)
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
                // sample light
                IntermediateLightSample ils = {};
                generateIntermediateLightSample(sg, ils);
                result += throughput * evalDirectConnection(sd, ils, mi, pathLength, sg);
            }
#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid() && pathLength < maxPathLength; depth++){
                // -------------------- BSDF Sampling ----------------------
                mi.sample(sd, sg, bsdfSample, kUseImportanceSampling);
                throughput *= bsdfSample.weight;
                
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                pathLength += hitT;

                if(hit.isValid() && (pathLength < maxPathLength) && any(throughput > 0.)){
                    // update sd, mi
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    // sample light
                    IntermediateLightSample ils = {};
                    generateIntermediateLightSample(sg, ils);
                    result += throughput * evalDirectConnection(sd, ils, mi, pathLength, sg);
                }
            }
#elif LIGHT_SAMPLING_METHOD == ELLIPSOIDAL_CONNECTION
            ///////////////////////////////////////////////////////////////
            // (0) Sample Light
            ///////////////////////////////////////////////////////////////
            IntermediateLightSample ils;
            generateIntermediateLightSample(sg, ils);

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
                float3 L = evalEllipsoidalConnection(sd, ils, mi, pathLength + ils.laserT, 
                    ellipsePdfA, directPdfA, sg);
                float misWeight = (ellipsePdfA > 0) ? ellipsePdfA / (ellipsePdfA + directPdfA) : 0.0;
                result += throughput * misWeight * L;
            }
#else 
            if(is_curr_diffuse){
                float ellipsePdfA = 0.0;
                float directPdfA = 0.0;
                float3 L = evalEllipsoidalConnection(sd, ils, mi, pathLength + ils.laserT, 
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
                    IntermediateLightSample ils;
                    generateIntermediateLightSample(sg, ils);

#if USE_ELLIPSOIDAL_DIRECT_MIS
                    ///////////////////////////////////////////////////////////////
                    // (1) Perform ellipsoidal (only if we have left path bounce)
                    ///////////////////////////////////////////////////////////////
                    if((depth < (kMaxBounces - 1)) && hasNonDeltaLobes)
                    {
                        float ellipsePdfA = 0.0;
                        float directPdfA = 0.0;
                        float3 L = evalEllipsoidalConnection(sd, ils, mi, pathLength + ils.laserT, 
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
                        float ellipseLength = length(sd.posW - prev_sd_posW) + length(sd.posW - ils.posW());
                        float ellipsePdfA = 0.0;
                        if(buildEllipsoidFromFoci(prev_sd_posW, ils.posW(), ellipseLength,
                            prev_sd_N, ils.getOrientedFaceNormal(), E))
                        {
                            ellipsePdfA = evalEllipsoidPdf(E, hit, sd, pathLength + ils.laserT - hitT);
                        };
                        float misWeight = directPdfA > 0 ? directPdfA / (ellipsePdfA + directPdfA) : 0.0;
                        
                        float3 L = evalDirectConnection(sd, ils, mi, pathLength, sg);
                        result += throughput * misWeight * L;
                    }
#else
                    ///////////////////////////////////////////////////////////////
                    // (1) Perform ellipsoidal (only if we have left path bounce and current is diffuse)
                    ///////////////////////////////////////////////////////////////
                    if((depth < (kMaxBounces - 1)) && is_curr_diffuse){
                        float ellipsePdfA = 0.0;
                        float directPdfA = 0.0;
                        float3 L = evalEllipsoidalConnection(sd, ils, mi, pathLength + ils.laserT, 
                            ellipsePdfA, directPdfA, sg);
                        result += throughput * L;
                    }
                    ///////////////////////////////////////////////////////////////
                    // (2) Perform direct if we did not perform ellipsoidal for previous vertex
                    ///////////////////////////////////////////////////////////////
                    if(!is_prev_diffuse && hasNonDeltaLobes){
                        float3 L = evalDirectConnection(sd, ils, mi, pathLength, sg);
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

float3 evalDirectConnection(
    const ShadingData sd, const IntermediateLightSample ils, const IMaterialInstance mi,
    float pathLength, inout SampleGenerator sg
)
{
    float3 toLightDir = normalize(ils.posW() - sd.posW);
    float toLightDistance = length(ils.posW() - sd.posW);
    if(toLightDistance < 1e-4){
        return float3(0.0);
    }
    float3 L = mi.eval(sd, toLightDir, sg) * ils.evalLi(sd.posW, sg);
    L *= pathLengthImportance(pathLength + toLightDistance + ils.laserT, tcurr);
    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDistance);
    return L * float(V);
}


float3 evalEllipsoidalConnection(
    const ShadingData sd, const IntermediateLightSample ils, const IMaterialInstance mi, 
    float pathLength, out float ellipsePdfA, out float directPdfA, inout SampleGenerator sg
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
        sd.posW, ils.posW(), tSampled,
        sd.getOrientedFaceNormal(), ils.getOrientedFaceNormal(), E))
    {
        return float3(0.0);
    }

    uint triangleIndex;
    float trianglePdf;

    if(!emissiveSampler.sampleTriangleEllipsoid(
        E, sg, triangleIndex, trianglePdf)){
        return float3(0.0);
    }
    const EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);

    // check if sd or ls is on triangle --> no need to check
    if(abs(dot(tri.normal, normalize(tri.posW[0] - sd.posW))) < 1e-4 
    || abs(dot(tri.normal, normalize(tri.posW[0] - ils.posW()))) < 1e-4){
        return float3(0.0);
    }

    // ellipsoid-triangle intersection
    SampleResultArea result = sampleOnTriangleEllipsoid(
        E,
        tri.posW[0], tri.posW[1], tri.posW[2],
        sampleNext1D(sg), sampleNext1D(sg));
    
    // valid result
    if(result.ok && !isinf(result.pdfA) && !isnan(result.pdfA)){
        pathLength = pathLength + length(sd.posW - result.p) + length(result.p - ils.posW());

        // shoot ray to sampled point from sd
        float hitT;
        HitInfo hit = traceRay(sd.computeRayOrigin(), normalize(result.p - sd.posW), hitT);
        ShadingData second_sd = loadShadingData(hit, sd.computeRayOrigin(), normalize(result.p - sd.posW));

        // TriangleHit triangleHit = hit.getTriangleHit();
        // uint actualTriangleIndex = gScene.triCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);

        // valid point?
        if(hitT > 0 && hit.isValid()
            && abs(dot(second_sd.getOrientedFaceNormal(), tri.normal)) > 0.999 
            && abs(hitT - length(sd.posW - result.p)) < 1e-3){
            
            let mi2 = gScene.materials.getMaterialInstance(second_sd, ExplicitLodTextureSampler(0));

            // float directPdfA = mi.evalPdf(sd, normalize(ellipseP - sd.posW));

            const float3 p1 = sd.posW;
            const float3 p2 = second_sd.posW;

            const float3 n2 = second_sd.getOrientedFaceNormal();
            const float3 l12 = p2 - p1;

            const float3 v12 = normalize(l12);
            const float d12 = length(p2 - p1);

            float3 f1 = mi.eval(sd, v12, sg);
            float3 f2 = mi2.eval(second_sd, -v12, sg);
            float3 Li = ils.evalLi(p2, sg);
            
            // .eval(laser_sd, v32, sg);
            float n21 = abs(dot(n2, -v12));
            float G12 = dot(l12, l12);
            if(G12 < 1e-9) return float3(0.0);

            float3 f = f1 * f2 * Li * n21 / (G12);

            float pdfA = trianglePdf * result.pdfA * pdfT;
            if(pdfA < 1e-9) return float3(0.0);
            f = f / pdfA; //max(, 1e-4f);
            // f /= pdfA;
            ellipsePdfA = pdfA;
            
            float directpdf = mi.evalPdf(sd, normalize(second_sd.posW - sd.posW));
            directPdfA = (G12 < 1e-9) ? 0.0 : directpdf * n21 / G12;

            bool V = traceVisibilityRay(second_sd.computeRayOrigin(), 
                normalize(ils.posW() - second_sd.posW), length(ils.posW() - second_sd.posW));

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
