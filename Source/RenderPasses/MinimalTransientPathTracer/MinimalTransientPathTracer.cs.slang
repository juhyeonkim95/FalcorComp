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
static const bool kUseAlphaTest = USE_ALPHA_TEST;
static const bool kUseSingleChannel = false;

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;


bool traceVisibilityRay(const float3 origin, const float3 dir, const float distance)
{
    Ray visibilityRay = Ray(origin, dir, 0.0, max(distance - 1e-4f, 1e-4f));
    SceneRayQuery<kUseAlphaTest> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

bool checkVisibility(const float3 origin, const float3 target)
{
    Ray visibilityRay = Ray(origin, normalize(target - origin), 0.0, max(length(target - origin) - 1e-4f, 1e-4f));
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

#if USE_KERNEL_DENSITY_ESTIMATION
void accumulateToHistogram(const uint2 pixel, float pathLength, float3 L, float window)
{
    uint idx;
    float residual;
    L /= (window * samplesPerPixel);
    for(int i=0; i<tbin; i++){
        float binCenter = tmin + (i + 0.5) * tunit;
        float pathLengthWeight = pathLengthImportanceGivenWindow(pathLength, binCenter, window);
        if(pathLengthWeight > 0.0){
            #if USE_SINGLE_CHANNEL
            gTransientHistogram[uint3(pixel.x, pixel.y, i)] += L.x * pathLengthWeight;
            #else
            gTransientHistogram[uint3(pixel.x, pixel.y, i)] += float4(L * pathLengthWeight, 1.0f);
            #endif
        }
    }
}
#else
void accumulateToHistogram(const uint2 pixel, float pathLength, float3 L, float window)
{
    uint idx;
    float residual;
    L /= (tunit * samplesPerPixel);
    if(getPathLengthIndex(pathLength, idx, residual)){
        uint idx2 = clamp(idx + 1, 0, tbin - 1);
#if USE_SINGLE_CHANNEL
#if HISTOGRAM_FILTER == HISTOGRAM_FILTER_BOX
        gTransientHistogram[uint3(pixel.x, pixel.y, idx)] += L.x;
#elif HISTOGRAM_FILTER == HISTOGRAM_FILTER_TENT
        gTransientHistogram[uint3(pixel.x, pixel.y, idx)] += (1.0 - residual) * L.x;
        gTransientHistogram[uint3(pixel.x, pixel.y, idx2)] += residual * L.x;
#endif
#else
#if HISTOGRAM_FILTER == HISTOGRAM_FILTER_BOX
        gTransientHistogram[uint3(pixel.x, pixel.y, idx)] += float4(L, 1.0f);
#elif HISTOGRAM_FILTER == HISTOGRAM_FILTER_TENT
        gTransientHistogram[uint3(pixel.x, pixel.y, idx)] += (1.0 - residual) * float4(L, 1.0f);
        gTransientHistogram[uint3(pixel.x, pixel.y, idx2)] += residual * float4(L, 1.0f);
#endif
#endif
    }
}
#endif

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
        
        float maxPathLength = tmax;
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, laserCosAngle, laserPower);
        
        float window = (tmax - tmin);
        float window_alpha = 0.8;

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
                LightSample ls = {};
                lls.generateLightSample(sg, ls);
                
                float pathLengthTotal = pathLength + length(ls.posW() - sd.posW) + ls.laserT;
                float3 L = throughput * evalDirectConnection(sd, ls, mi, sg);
                result += L;

                // accumulate to histogram
                accumulateToHistogram(pixel, pathLengthTotal, L, window);
            }

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
                    LightSample ls = {};
                    lls.generateLightSample(sg, ls);
                    
                    float pathLengthTotal = pathLength + length(ls.posW() - sd.posW) + ls.laserT;
                    float3 L = throughput * evalDirectConnection(sd, ls, mi, sg);
                    // L *= float(depth == 2);
                    
                    result += L;

                    // accumulate to histogram
                    accumulateToHistogram(pixel, pathLengthTotal, L, window);
                }
            }
            
            window *= (i+window_alpha) / (i + 1.0);

            outColor += result;
        }
        outColor /= samplesPerPixel;

        outColor = sd0.posW;
    }
    else
    {
        // Background pixel.
        outColor = float3(0,0,0);
        // outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }
    return outColor;
}

float3 evalDirectConnection(
    const ShadingData sd, const LightSample ls, const IMaterialInstance mi, inout SampleGenerator sg
)
{
    float3 toLightDir = normalize(ls.posW() - sd.posW);
    float toLightDistance = length(ls.posW() - sd.posW);
    if(toLightDistance < 1e-4){
        return float3(0.0);
    }
    float3 L = mi.eval(sd, toLightDir, sg) * ls.evalLi(sd.posW, sg);
    bool V = traceVisibilityRay(sd.computeRayOrigin(), toLightDir, toLightDistance);
    return L * float(V);
}



float3 integrateLinearGate(float ls[3], float3 fs[3], float l, float l_width)
{
    // --- sort by ls (simple bubble sort for 3 elements) ---
    // for (int i = 0; i < 2; i++)
    // {
    //     for (int j = i + 1; j < 3; j++)
    //     {
    //         if (ls[i] > ls[j])
    //         {
    //             float tmp = ls[i]; ls[i] = ls[j]; ls[j] = tmp;
    //             float3 tmp3 = fs[i]; fs[i] = fs[j]; fs[j] = tmp3;
    //         }
    //     }
    // }

    float gateMin = l - 0.5 * l_width;
    float gateMax = l + 0.5 * l_width;
    float fmin = ls[0];
    float fmax = ls[2];

    // If gate is completely outside the defined range → return 0
    if (gateMax <= fmin || gateMin >= fmax)
        return 0.0;

    float3 total = 0.0;

    // Integrate segment by segment
    for (int i = 0; i < 2; i++)
    {
        float x0 = ls[i];
        float x1 = ls[i + 1];
        float3 y0 = fs[i];
        float3 y1 = fs[i + 1];

        // Segment overlap with gate
        float segMin = max(x0, gateMin);
        float segMax = min(x1, gateMax);
        if (segMax <= segMin) continue;

        // Linear interpolation at overlap edges
        float3 f0 = y0 + (y1 - y0) * (segMin - x0) / (x1 - x0);
        float3 f1 = y0 + (y1 - y0) * (segMax - x0) / (x1 - x0);

        // Integral of a linear segment = (width * average height)
        total += 0.5 * (f0 + f1) * (segMax - segMin);
    }

    return total / (fmax - fmin);
}

float3 tracePathTriangleApprox(const uint2 pixel, const uint2 frameDim)
{
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 151);

        // first hit point
        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        BSDFProperties bsdfProperties0 = mi0.getProperties(sd0);
        float d01 = length(sd0.posW - primaryRayOrigin);

        // sample collimated laser (force cosAngle to one)
        LaserLightSampler lls = LaserLightSampler(laserOrigin, laserDirection, 1.0, laserPower);
        LightSample ls = {};
        lls.generateLightSample(sg, ls); // laser hit point
                
        uint triangleCount = gScene.triCollection.getActiveTriangleCount();

        float eps = 1e-4;
        float barycentric_xs[3] = {eps, 1-eps, eps};
        float barycentric_ys[3] = {eps, eps, 1-eps};
        // float barycentric_xs[3] = {1.0/3.0, 1.0/3.0, 1.0/3.0};
        // float barycentric_ys[3] = {1.0/3.0, 1.0/3.0, 1.0/3.0};
        // emissiveSampler.sampleTriangle();

        // iterate over ALL triangles:
        for(int i=0; i<triangleCount; i++){
            uint triangleIndex = gScene.triCollection.activeTriangles[i];
            const EmissiveTriangle tri = gScene.triCollection.getTriangle(triangleIndex);
            float3 centerPoint = (tri.posW[0] + tri.posW[1] + tri.posW[2]) / 3.0;

            float3 d12 = normalize(centerPoint - sd0.posW);
            float3 l12 = length(d12);

            // on same plane --> skip
            if(abs(dot(d12, sd0.getOrientedFaceNormal())) < 1e-5){
                continue;
            }

            // trace ray toward triangle center
            float hitT;
            HitInfo triCenterHit = traceRay(sd0.computeRayOrigin(), d12, hitT);
            ShadingData triCenterHitSd = loadShadingData(triCenterHit, sd0.computeRayOrigin(), d12);
            
            if(triCenterHit.isValid() && length(triCenterHitSd.posW - centerPoint) < 1e-2 
                && abs(dot(triCenterHitSd.faceN, tri.normal)) > 0.99 && checkVisibility(triCenterHitSd.computeRayOrigin(), ls.posW()))
            {
                float3 fs[3];
                float pls[3];
                for(int j=0; j<3; j++){
                    TriangleHit triangleHit;
                    triangleHit.instanceID = triCenterHit.getInstanceID();
                    triangleHit.primitiveIndex = triCenterHit.getPrimitiveIndex();
                    triangleHit.barycentrics[0] = barycentric_xs[j];
                    triangleHit.barycentrics[1] = barycentric_ys[j];
                    HitInfo vertexHit = HitInfo(triangleHit);

                    float3 vertexPos = tri.posW[0] * (1 - barycentric_xs[j] - barycentric_ys[j]) + tri.posW[1] * barycentric_xs[j] + tri.posW[2] * barycentric_ys[j];
                    ShadingData secondHitsd = loadShadingData(vertexHit, sd0.computeRayOrigin(), normalize(vertexPos - sd0.posW));

                    let second_hit_mi = gScene.materials.getMaterialInstance(secondHitsd, ExplicitLodTextureSampler(0.f));

                    float3 f1 = mi0.eval(sd0, normalize(secondHitsd.posW - sd0.posW), sg);
                    float3 f2 = second_hit_mi.eval(secondHitsd, normalize(ls.posW() - secondHitsd.posW), sg);
                    float3 Li = ls.evalLi(secondHitsd.posW, sg);
                    
                    float n21 = abs(dot(secondHitsd.getOrientedFaceNormal(), -normalize(centerPoint - sd0.posW)));
                    
                    float d12 = length(sd0.posW - secondHitsd.posW);
                    float G12 = d12 * d12;

                    float d23 = length(ls.posW() - secondHitsd.posW);
                    // float G23 = d23 * d23;

                    float pathLength = d01 + d12 + d23 + ls.laserT;
                    pls[j] = pathLength;

                    float3 f = f1 * f2 * Li * n21 / (G12) * tri.area;

                    fs[j] = f;
                }

                // --- sort by ls (simple bubble sort for 3 elements) ---
                for (int k = 0; k < 2; k++)
                {
                    for (int j = k + 1; j < 3; j++)
                    {
                        if (pls[k] > pls[j])
                        {
                            float tmp = pls[k]; pls[k] = pls[j]; pls[j] = tmp;
                            float3 tmp3 = fs[k]; fs[k] = fs[j]; fs[j] = tmp3;
                        }
                    }
                }
                
                uint timeBinIdxMin = uint((pls[0] - tmin) / (tmax - tmin) * tbin);
                uint timeBinIdxMax = uint((pls[2] - tmin) / (tmax - tmin) * tbin);

                timeBinIdxMin = clamp(timeBinIdxMin, 0, tbin - 1);
                timeBinIdxMax = clamp(timeBinIdxMax, 0, tbin - 1);
                
                float time_gate_unit = (tmax - tmin) / tbin;

                for(int j=0; j<tbin; j++){
                    float3 L = integrateLinearGate(pls, fs, tmin + j * time_gate_unit, time_gate_unit) / time_gate_unit;
                    #if USE_SINGLE_CHANNEL
                    gTransientHistogram[uint3(pixel.x, pixel.y, j)] += L.x;
                    #else
                    gTransientHistogram[uint3(pixel.x, pixel.y, j)] += float4(L, 1.0f);
                    #endif
                    // gTransientHistogram[uint3(pixel.x, pixel.y, j)] += 
                    //     integrateLinearGate(pls, fs, tmin + j * time_gate_unit, time_gate_unit) / time_gate_unit;
                }
            }
        }
    }
    return float3(1.0);
}



[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
#if LIGHT_SAMPLING_METHOD == DIRECT_CONNECTION
    float3 color = tracePath(pixel, gFrameDim);
#elif LIGHT_SAMPLING_METHOD == TRIANGLE_APPROX
    float3 color = tracePathTriangleApprox(pixel, gFrameDim);
#endif
    gOutputColor[pixel] = float4(color, 1.f);
}
