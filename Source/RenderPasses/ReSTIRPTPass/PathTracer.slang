/***************************************************************************
 # Copyright (c) 2022, Daqi Lin.  All rights reserved.
 **************************************************************************/
// #include "Scene/Material/MaterialDefines.slangh"

import Scene.RaytracingInline;
// import Rendering.Lights.EnvMapSampler;
// import Rendering.Lights.EmissiveLightSampler;
// import Rendering.Lights.EmissiveLightSamplerHelpers;
// import Rendering.Lights.LightHelpers;
// import Rendering.Materials.StandardMaterial;
// import Rendering.Materials.ClothMaterial;
// import Rendering.Materials.HairMaterial;
// //import Rendering.Materials.MaterialShading;
// import Rendering.Materials.Microfacet;
// import Rendering.Materials.InteriorListHelpers;
// import Rendering.Volumes.HomogeneousVolumeSampler;
// import Rendering.Volumes.PhaseFunction;
// import Rendering.Utils.PixelStats;
// import RenderPasses.Shared.Denoising.NRDBuffers;
// import RenderPasses.Shared.Denoising.NRDData;
// import RenderPasses.Shared.Denoising.NRDHelpers;
// import RenderPasses.Shared.Denoising.NRDConstants;
// import NRDHelpers;
// import Utils.Color.ColorHelpers;
// import Utils.Geometry.GeometryHelpers;
// import Utils.Debug.PixelDebug;
// import LoadShadingData;
// import PathBuilder;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Materials.IsotropicGGX;
import Rendering.Materials.InteriorListHelpers;
import Rendering.Volumes.HomogeneousVolumeSampler;
import Rendering.Utils.PixelStats;
import RenderPasses.Shared.Denoising.NRDConstants;
import RenderPasses.Shared.Denoising.NRDBuffers;
import RenderPasses.Shared.Denoising.NRDData;
// import RenderPasses.Shared.Denoising.NRDHelpers;
import Utils.Color.ColorHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Debug.PixelDebug;
import LoadShadingData;
// import ColorType;
// import NRDHelpers;
// __exported import PathState;
__exported import Params;
import PathReservoir;

#include "Utils/Math/MathConstants.slangh"

__exported import PathState;
__exported import Params;

uint getAllowedBSDFFlags(bool isSpecularBounce)
{
    if (kSeparatePathBSDF) return isSpecularBounce ? 0xc : 0x3;
    else return -1;
}

struct PathTracer
{
    RestirPathTracerParams params;                  ///< Runtime parameters.
    EnvMapSampler envMapSampler;                    ///< Environment map sampler. Only valid when kUseEnvLight == true.
    EmissiveLightSampler emissiveSampler;           ///< Emissive light sampler. Only valid when kUseEmissiveLights == true.

    Texture2D<PackedHitInfo> vbuffer;               ///< Fullscreen V-buffer for the primary hits.

    NRDBuffers outputNRD;                           ///< Output NRD data.
    RWTexture2D<float4> outputNRDDiffuseRadianceHitDist;    ///< Output resolved diffuse color in .rgb and hit distance in .a for NRD. Only valid if kOutputNRDData == true.
    RWTexture2D<float4> outputNRDSpecularRadianceHitDist;   ///< Output resolved specular color in .rgb and hit distance in .a for NRD. Only valid if kOutputNRDData == true.
    RWTexture2D<float4> outputNRDResidualRadianceHitDist;   ///< Output resolved residual color in .rgb and hit distance in .a for NRD. Only valid if kOutputNRDData == true.

    RWTexture2D<float4> outputColor;                ///< Output color buffer if kSamplesPerPixel == 1.
    RWTexture2D<float4> outputDebug;                ///< Output debug data. Valid if OUTPUT_DEBUG is nonzero.
    RWTexture2D<uint> outputTime;                   ///< Output timing data. Valid if OUTPUT_TIME is nonzero.

    Texture2D<float4> directLighting;                   ///< Output offset into per-sample buffers. Only valid when kSamplesPerPixel == 0.

    RWStructuredBuffer<PathReservoir> outputReservoirs;            ///< Output paths from the path tracing pass.
    bool isLastRound;
    bool useDirectLighting;
    int  gSppId;
    int  gNumSpatialRounds;

    /*******************************************************************
                                Static members
    *******************************************************************/

    // Render settings that depend on the scene.
    // TODO: Move into scene defines.
    //static bool kUseEnvLight = USE_ENV_LIGHT;
    //static bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
    //static bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
    bool kUseEnvLight;
    bool kUseEmissiveLights;
    bool kUseAnalyticLights;

    // Render settings that depend on the scene.
    // TODO: Move into scene defines.
    // static const bool kUseEnvLight = USE_ENV_LIGHT;
    // static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
    // static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
    static const bool kUseCurves = USE_CURVES;
    static const bool kUseHairMaterial = USE_HAIR_MATERIAL;

    // Additional specialization.
    static const bool kOutputTime = OUTPUT_TIME;

    /** Types of samplable lights.
    */
    enum class LightSampleType
    {
        EnvMap,
        Emissive,
        Analytic
    };

    /** Describes a light sample.
    */
    struct LightSample
    {
        float3  Li;         ///< Incident radiance at the shading point (unshadowed). This is already divided by the pdf.
        float   pdf;        ///< Pdf with respect to solid angle at the shading point.
        float3  origin;     ///< Ray origin for visibility evaluation (offseted to avoid self-intersection).
        float   distance;   ///< Ray distance for visibility evaluation (shortened to avoid self-intersection).
        float3  dir;        ///< Ray direction for visibility evaluation (normalized).
        uint    lightType;  ///< Light type this sample comes from (LightType casted to uint).

        Ray getVisibilityRay() { return Ray(origin, dir, 0.f, distance); }
    };

    /** Describes a path vertex.
    */
    struct PathVertex
    {
        uint index;         ///< Vertex index (0 = camera, 1 = primary hit, 2 = secondary hit, etc.).
        float3 pos;         ///< Vertex position.
        float3 faceNormal;  ///< Geometry normal at the vertex (zero if not on a surface).
        bool frontFacing;   ///< True if path vertex is on the front-facing side (if on a surface).

        /** Initializes a path vertex.
            \param[in] index Vertex index.
            \param[in] pos Vertex position.
            \param[in] faceNormal Geometry normal.
            \param[in] frontFacing Front-facing flag.
        */
        __init(uint index, float3 pos, float3 faceNormal = float3(0.f), bool frontFacing = true)
        {
            this.index = index;
            this.pos = pos;
            this.faceNormal = faceNormal;
            this.frontFacing = frontFacing;
        }

        /** Get position with offset applied in direction of the geometry normal to avoid self-intersection
            for visibility rays.
            \param[in] rayDir Direction of the visibility ray (does not need to be normalized).
            \return Returns the offseted position.
        */
        float3 getRayOrigin(float3 rayDir)
        {
            return computeRayOrigin(pos, dot(faceNormal, rayDir) >= 0 ? faceNormal : -faceNormal);
        }

        /** Returns the oriented face normal.
            \return Face normal flipped to the same side as the view vector.
        */
        float3 getOrientedFaceNormal()
        {
            return frontFacing ? faceNormal : -faceNormal;
        }
    };


    /** Generate the path state for a primary hit in screen space.
        This is treated equivalent to subsequent path vertices to reduce code divergence.
        \param[in] pathID Path ID which encodes pixel and sample index.
        \param[out] path Path state for the primary hit.
    */
    void generatePath(const uint pathID, out PathState path){
        path = {};
        path.setActive();
        path.id = pathID;
        path.thp = float3(1.f);
        path.prefixThp = float3(1.f);
        path.rcVertexPathTreeIrradiance = float3(0.f);

        path.LDeltaDirect = float3(0.f);
        path.enableRandomReplay = false;
        path.useHybridShift = ShiftMapping(kShiftStrategy) == ShiftMapping::Hybrid;
        path.isLastVertexClassifiedAsRough = true;
        path.isReplayForHybridShift = false;

        // Load the primary hit info from the V-buffer.
        // If invalid, the path is still active and treated as a miss.
        uint2 pixel = path.getPixel();
        const HitInfo hit = HitInfo(vbuffer[pixel]);

        if (hit.isValid())
        {
            path.setHit(hit);
            //path.setVertexIndex(1);
        }

        // TODO: Support depth-of-field using computeRayThinlens, if aperture size > 0.
        Ray cameraRay = gScene.camera.computeRayPinhole(pixel, params.frameDim);
        path.origin = cameraRay.origin;
        path.dir = cameraRay.dir;

        // Create sample generator.
        static const uint itersPerShaderPass = PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing ? kSamplesPerPixel : kCandidateSamples;
        
        uint maxSpp = itersPerShaderPass > 0 ? itersPerShaderPass : kMaxSamplesPerPixel;
        path.sg = SampleGenerator(pixel, (itersPerShaderPass + 1 + gNumSpatialRounds) * params.seed + path.getSampleIdx());

        if (kOutputNRDData)
        {
            path.hitDist = 0;
            path.rcPrevVertexWo = 0;
            path.sharedScatterDir = 0;
        }

        path.pathBuilder.init(path.sg);
        path.pathReservoir.init();
    }

    /** Check if the path has finished all surface bounces and needs to be terminated.
        Note: This is expected to be called after generateScatterRay(), which increments the bounce counters.
        \param[in] path Path state.
        \return Returns true if path has processed all bounces.
    */
    bool hasFinishedSurfaceBounces(const PathState path)
    {
        const uint diffuseBounces = path.getBounces(BounceType::Diffuse);
        const uint specularBounces = path.getBounces(BounceType::Specular);
        const uint transmissionBounces = path.getBounces(BounceType::Transmission);
        const uint surfaceBounces = diffuseBounces + specularBounces + transmissionBounces;
        return
            (surfaceBounces > kMaxSurfaceBounces) ||
            (diffuseBounces > kMaxDiffuseBounces) ||
            (specularBounces > kMaxSpecularBounces) ||
            (transmissionBounces > kMaxTransmissionBounces);
    }

    /** Helper to create a texture sampler instance.
        The method for computing texture level-of-detail depends on the configuration.
        \param[in] path Path state.
        \param[in] isPrimaryTriangleHit True if primary hit on a triangle.
        \return Texture sampler instance.
    */
    ITextureSampler createTextureSampler(const PathState path, bool isPrimaryHit)
    {
        const bool isTriangleHit = (path.hit.getType() == HitType::Triangle);
        if (kPrimaryLodMode == TexLODMode::RayDiffs && isPrimaryHit && isTriangleHit)
        {
            // Filtered lookups at primary hit on triangle.
            float2 ddx, ddy;
            computeDerivativesAtPrimaryTriangleHit(path.hit.getTriangleHit(), path.getPixel(), params.frameDim, ddx, ddy);
            return ExplicitGradientTextureSampler(ddx, ddy);
        }
        else
        {
            float lod = isPrimaryHit ? 0.f : params.lodBias;
            return ExplicitLodTextureSampler(lod);
        }
    }

    /** Return the probabilities for selecting different light types.
        \param[out] p Probabilities.
    */
    void getLightTypeSelectionProbabilities(out float p[3])
    {
        // Set relative probabilities of the different sampling techniques.
        // TODO: These should use estimated irradiance from each light type. Using equal probabilities for now.
        p[0] = kUseEnvLight ? 1.f : 0.f;
        p[1] = kUseEmissiveLights ? 1.f : 0.f;
        p[2] = kUseAnalyticLights ? 1.f : 0.f;

        // Normalize probabilities. Early out if zero.
        float sum = p[0] + p[1] + p[2];
        if (sum == 0.f) return;

        float invSum = 1.f / sum;
        p[0] *= invSum;
        p[1] *= invSum;
        p[2] *= invSum;
    }

    float getEnvMapSelectionProbability()   { float p[3]; getLightTypeSelectionProbabilities(p); return p[0]; }
    float getEmissiveSelectionProbability() { float p[3]; getLightTypeSelectionProbabilities(p); return p[1]; }
    float getAnalyicSelectionProbability()  { float p[3]; getLightTypeSelectionProbabilities(p); return p[2]; }
    
    /** Select a light type for sampling.
        \param[out] lightType Selected light type.
        \param[out] pdf Probability for selected type.
        \param[in,out] sg Sample generator.
        \return Return true if selection is valid.
    */
    bool selectLightType(out uint lightType, out float pdf, inout SampleGenerator sg)
    {
        float p[3];
        getLightTypeSelectionProbabilities(p);

        float u = sampleNext1D(sg);

        [unroll]
        for (lightType = 0; lightType < 3; ++lightType)
        {
            if (u < p[lightType])
            {
                pdf = p[lightType];
                return true;
            }
            u -= p[lightType];
        }

        return false;
    }

    /** Trace a visibility ray to evaluate light visibility.
        \param[in] ray Visibility ray.
        \return true if the light is visible, false if occluded.
    */
    bool traceVisibilityRay(const Ray ray)
    {
        // TODO rename to PixelStatsRayType::Visibility
        // logTraceRay(PixelStatsRayType::Shadow);
        SceneRayQuery<kUseAlphaTest> sceneRayQuery;
        return sceneRayQuery.traceVisibilityRay(ray);
    }
    
    /** Samples a light source in the scene.
        This function first stochastically selects a type of light source to sample,
        and then calls that the sampling function for the chosen light type.
        \param[in] vertex Path vertex.
        \param[in] sampleUpperHemisphere True if the upper hemisphere should be sampled.
        \param[in] sampleLowerHemisphere True if the lower hemisphere should be sampled.
        \param[in,out] sg Sample generator.
        \param[out] ls Struct describing valid samples.
        \return True if the sample is valid and has nonzero contribution, false otherwise.
    */
    bool generateLightSample(const PathVertex vertex, const bool sampleUpperHemisphere, const bool sampleLowerHemisphere, inout SampleGenerator sg, out LightSample ls)
    {
        ls = {};

        uint lightType;
        float selectionPdf;
        if (!selectLightType(lightType, selectionPdf, sg)) return false;

        bool valid = false;
        if (kUseEnvLight && lightType == (uint)LightSampleType::EnvMap) valid = generateEnvMapSample(vertex, sg, ls);
        if (kUseEmissiveLights && lightType == (uint)LightSampleType::Emissive)
        {
            // Emissive light samplers have an option to exclusively sample the upper hemisphere.
            bool upperHemisphere = sampleUpperHemisphere && !sampleLowerHemisphere;
            valid = generateEmissiveSample(vertex, upperHemisphere, sg, ls);
        }
        if (kUseAnalyticLights && lightType == (uint)LightSampleType::Analytic)
        {
            valid = generateAnalyticLightSample(vertex, sg, ls);
        }
        if (!valid) return false;

        // Reject samples in non-requested hemispheres.
        float NdotL = dot(vertex.getOrientedFaceNormal(), ls.dir);
        if ((!sampleUpperHemisphere && NdotL >= -kMinCosTheta) || (!sampleLowerHemisphere && NdotL <= kMinCosTheta))
            return false;

        // Account for light type selection.
        ls.lightType = lightType;
        ls.pdf *= selectionPdf;
        ls.Li /= selectionPdf;

        return true;
    }

    /** Generates a light sample on the environment map.
        \param[in] vertex Path vertex.
        \param[in,out] sg Sample generator.
        \param[out] ls Struct describing valid samples.
        \return True if the sample is valid and has nonzero contribution, false otherwise.
    */
    bool generateEnvMapSample(const PathVertex vertex, inout SampleGenerator sg, out LightSample ls)
    {
        ls = {}; // Default initialization to avoid divergence at returns.

        if (!kUseEnvLight) return false;

        // Sample environment map.
        EnvMapSample lightSample;
        if (!envMapSampler.sample(sampleNext2D(sg), lightSample)) return false;

        // Setup returned sample.
        ls.Li = lightSample.pdf > 0.f ? lightSample.Le / lightSample.pdf : float3(0);
        ls.pdf = lightSample.pdf;
        ls.origin = vertex.getRayOrigin(lightSample.dir);
        ls.distance = kRayTMax;
        ls.dir = lightSample.dir;

        return any(ls.Li > 0.f);
    }

    /** Generates a light sample on the emissive geometry.
        \param[in] vertex Path vertex.
        \param[in] upperHemisphere True if only upper hemisphere should be considered.
        \param[in,out] sg Sample generator.
        \param[out] ls Struct describing valid samples.
        \return True if the sample is valid and has nonzero contribution, false otherwise.
    */
    bool generateEmissiveSample(const PathVertex vertex, const bool upperHemisphere, inout SampleGenerator sg, out LightSample ls)
    {
        ls = {}; // Default initialization to avoid divergence at returns.
        if (!kUseEmissiveLights) return false;

        TriangleLightSample tls;
        if (!emissiveSampler.sampleLight(vertex.pos, vertex.getOrientedFaceNormal(), upperHemisphere, sg, tls)) return false;

        // Setup returned sample.
        ls.Li = tls.pdf > 0.f ? tls.Le / tls.pdf : float3(0);
        ls.pdf = tls.pdf;
        // Offset shading and light position to avoid self-intersection.
        float3 lightPos = computeRayOrigin(tls.posW, tls.normalW);
        ls.origin = vertex.getRayOrigin(lightPos - vertex.pos);
        float3 toLight = lightPos - ls.origin;
        ls.distance = length(toLight);
        ls.dir = normalize(toLight);

        return any(ls.Li > 0.f);
    }

    /** Generates a light sample on the analytic lights.
        \param[in] vertex Path vertex.
        \param[in,out] sg Sample generator.
        \param[out] ls Struct describing valid samples.
        \return True if the sample is valid and has nonzero contribution, false otherwise.
    */
    bool generateAnalyticLightSample(const PathVertex vertex, inout SampleGenerator sg, out LightSample ls)
    {
        ls = {}; // Default initialization to avoid divergence at returns.

        uint lightCount = gScene.getLightCount();
        if (!kUseAnalyticLights || lightCount == 0) return false;

        // Sample analytic light source selected uniformly from the light list.
        // TODO: Sample based on estimated contributions as pdf.
        uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);

        // Sample local light source.
        AnalyticLightSample lightSample;
        if (!sampleLight(vertex.pos, gScene.getLight(lightIndex), sg, lightSample)) return false;

        // Setup returned sample.
        ls.pdf = lightSample.pdf / lightCount;
        ls.Li = lightSample.Li * lightCount;
        // Offset shading position to avoid self-intersection.
        ls.origin = vertex.getRayOrigin(lightSample.dir);
        // Analytic lights do not currently have a geometric representation in the scene.
        // Do not worry about adjusting the ray length to avoid self-intersections at the light.
        ls.distance = lightSample.distance;
        ls.dir = lightSample.dir;

        return any(ls.Li > 0.f);
    }

    /** Evaluates the currently configured heuristic for multiple importance sampling (MIS).
        \param[in] n0 Number of samples taken from the first sampling strategy.
        \param[in] p0 Pdf for the first sampling strategy.
        \param[in] n1 Number of samples taken from the second sampling strategy.
        \param[in] p1 Pdf for the second sampling strategy.
        \return Weight for the contribution from the first strategy (p0).
    */
    float evalMIS(float n0, float p0, float n1, float p1)
    {
        switch (MISHeuristic(kMISHeuristic))
        {
        case MISHeuristic::Balance:
        {
            // Balance heuristic
            float q0 = n0 * p0;
            float q1 = n1 * p1;
            return q0 / (q0 + q1);
        }
        case MISHeuristic::PowerTwo:
        {
            // Power two heuristic
            float q0 = (n0 * p0) * (n0 * p0);
            float q1 = (n1 * p1) * (n1 * p1);
            return q0 / (q0 + q1);
        }
        case MISHeuristic::PowerExp:
        {
            // Power exp heuristic
            float q0 = pow(n0 * p0, kMISPowerExponent);
            float q1 = pow(n1 * p1, kMISPowerExponent);
            return q0 / (q0 + q1);
        }
        default:
            return 0.f;
        }
    }

    void invalidateAndTerminateReplayPath(inout PathState path)
    {
        path.rcPrevVertexHit = HitInfo();
        path.rcPrevVertexWo = float3(0);
        path.L = 0.f;
        path.thp = 0.f;
        path.terminate();
    }

    void skipLightSampleRandomNumbers(inout SampleGenerator sg)
    {
        uint lightType;
        float selectionPdf;
        if (!selectLightType(lightType, selectionPdf, sg)) return;

        bool valid = false;
        if (kUseEnvLight && lightType == (uint)LightSampleType::EnvMap)
        {
            if (!kUseEnvLight) valid = false;
            else sampleNext2D(sg);
        }
        if (kUseEmissiveLights && lightType == (uint)LightSampleType::Emissive)
        {
            if (!kUseEmissiveLights) valid = false;
            else emissiveSampler.skipRandomNumber(sg);
        }
        if (kUseAnalyticLights && lightType == (uint)LightSampleType::Analytic)
        {
            analyticLightSampleSkipRandomNumber(sg);
        }
    }

    void analyticLightSampleSkipRandomNumber(inout SampleGenerator sg)
    {
        uint lightCount = gScene.getLightCount();
        if (!kUseAnalyticLights || lightCount == 0) return;
        uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);

        LightData light = gScene.getLight(lightIndex);

        switch (light.type)
        {
        case LightType::Rect:
        case LightType::Sphere:
        case LightType::Disc:
        case LightType::Distant:
            sampleNext2D(sg);
        default:
        }
    }

    /** Apply russian roulette to terminate paths early.
        \param[in,out] path Path.
        \return Returns true if path was terminated.
    */
    bool terminatePathByRussianRoulette(inout PathState path)
    {
        const float rrVal = luminance(path.getCurrentThp());
        const float prob = max(0.f, 1.f - rrVal);
        if (sampleNext1D(path.sg) < prob)
        {
            path.terminate();
            return true;
        }

        path.russianRoulettePdf *= 1.f - prob;

        return false;
    }

    /** Handle the case when a scatter ray hits the scene.
        After handling the hit, a new scatter ray is generated or the path is terminated.
        \param[in,out] path The path state.
    */
    void handleHit(inout PathState path)
    {
        // Upon hit:
        // - Load vertex/material data
        // - Compute volume absorption
        // - Compute MIS weight if path.length > 0 and emissive hit
        // - Add emitted radiance
        // - Sample light(s) using shadow rays
        // - Sample scatter ray or terminate

        // Check if this is the primary hit.
        const bool isPrimaryHit = path.length == 0;

        TriangleHit th = path.hit.getTriangleHit();
        bool isCurveHit = path.hit.getType() == HitType::Curve;


        // Load shading data. This is a long latency operation.
        ShadingData sd = loadShadingData(path.hit, path.origin, path.dir);

        // Reject false hits in nested dielectrics.
        if (!handleNestedDielectrics(sd, path)) return;

        logPathVertex();

        // Create texture sampler.
        let lod = createTextureSampler(path, isPrimaryHit);

        // Create BSDF instance and query its properties.
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, lod);
        BSDFProperties bsdfProperties = mi.getProperties(sd);
        
        // Disable specular lobes if caustics are disabled and path already contains a diffuse vertex.
        bool isSpecular = bsdfProperties.roughness <= params.specularRoughnessThreshold;
        if (kDisableCaustics && path.getBounces(BounceType::Diffuse) > 0 && isSpecular)
        {
            sd.mtl.setActiveLobes((uint)LobeType::Diffuse);
        }

        // Optionally disable emission inside volumes.
        if (!kUseLightsInDielectricVolumes && path.isInsideDielectricVolume())
        {
            bsdfProperties.emission = float3(0.f);
        }

        // Check if the scatter event is samplable by the light sampling technique.
        const bool isLightSamplable = path.isLightSamplable();

        
        // Add emitted radiance.
        // The primary hit is always included, secondary hits only if emissive lights are enabled and the full light contribution hasn't been sampled elsewhere.
        bool computeEmissive = isPrimaryHit || kUseEmissiveLights && (!kUseNEE || kUseMIS || !path.isLightSampled() || !isLightSamplable);

        // Disable all constributions to direct illumination if requested. (but we need LDeltaDirect which cannot be sampled by ReSTIR DI)
        if (kDisableDirectIllumination && path.length == 1 && isLightSamplable) computeEmissive = false;

        if (path.length == 1 && !path.isTransmission() && !path.isDelta()) computeEmissive = false;

        // daqi: when doing random number replay, we will terminate the path when the length reaches the base path length and 
        // when the path types match. In this case, if the base path is a escaped path (as opposed to an NEE path), we should terminate when we 
        // find that offset path can also be an escaped path
        bool terminateRandomReplayForEscape = path.enableRandomReplay && path.length - 1 == path.randomReplayLength && path.randomReplayIsEscaped && path.randomReplayLength >= 1;

        float3 attenuatedEmission = 0.f;

        if (computeEmissive && any(bsdfProperties.emission > 0.f))
        {
            float lightPdf = 0.f;
            float misWeight = 1.f;
            float3 Lr = 0.f;

            if (kUseEmissiveLights && kUseNEE && kUseMIS && !isPrimaryHit && path.isLightSampled() && isLightSamplable)
            {
                // If NEE and MIS are enabled, and we've already sampled emissive lights,
                // then we need to evaluate the MIS weight here to account for the remaining contribution.
                // Note that MIS is only applied for hits on emissive triangles (other emissive geometry is not supported).

                // Prepare hit point struct with data needed for emissive light PDF evaluation.
                TriangleLightHit hit;
                TriangleHit triangleHit = path.hit.getTriangleHit();
                hit.triangleIndex = gScene.lightCollection.getTriangleIndex(triangleHit.instanceID, triangleHit.primitiveIndex);
                hit.posW = sd.posW;
                hit.normalW = sd.getOrientedFaceNormal();

                // Evaluate PDF at the hit, had it been generated with light sampling.
                // Emissive light samplers have an option to exclusively sample the upper hemisphere.
                bool upperHemisphere = path.isLightSampledUpper() && !path.isLightSampledLower();
                lightPdf = getEmissiveSelectionProbability() * emissiveSampler.evalPdf(path.origin, path.normal, upperHemisphere, hit);

                // Compute MIS weight by combining this with BSDF sampling.
                // Note we can assume path.pdf > 0.f since we shouldn't have got here otherwise.
                misWeight = evalMIS(1, path.pdf, 1, lightPdf);
            }

            // Accumulate emitted radiance weighted by path throughput and MIS weight.
            if (!kDisableDirectIllumination || !isPrimaryHit || !isLightSamplable)
                Lr = path.getCurrentThp() * bsdfProperties.emission * misWeight;

            attenuatedEmission = path.getCurrentThp() * bsdfProperties.emission; //only used for primary hit

            // daqi: Since ScreenSpaceReSTIR cannot handle transmission and delta reflection, we must include the contribution in the color buffer 
            if (!path.enableRandomReplay || terminateRandomReplayForEscape)
            {
                if (!kDisableDirectIllumination || path.length > 1) path.L += Lr;
                // will change this to path.IsDelta() if ScreenSpaceReSTIR can handle transmission
                if (!isLightSamplable && path.length == 1) path.LDeltaDirect += Lr;
            }




            // daqi: here we are adding the path terminated with an escaped vertex
            if ((!path.enableRandomReplay || terminateRandomReplayForEscape) && PathSamplingMode(kPathSamplingMode) != PathSamplingMode::PathTracing)
            {
#if BPR
                if (path.length - 1 > path.pathBuilder.rcVertexLength)
                {
                    path.rcVertexPathTreeIrradiance += path.thp * bsdfProperties.emission * misWeight;
                }
                bool selectedCurrentPath = path.pathBuilder.addEscapeVertex(params, max(0, path.length - 1), path.dir, Lr,
                    path.length - 1 == path.pathBuilder.rcVertexLength ? path.thp * bsdfProperties.emission * misWeight : path.rcVertexPathTreeIrradiance,
                    path.useHybridShift, path.russianRoulettePdf, misWeight, lightPdf, (uint)LightSampleType::Emissive, path.pathReservoir, path.enableRandomReplay);
#else
                bool selectedCurrentPath = path.pathBuilder.addEscapeVertex(params, max(0, path.length - 1), path.dir, Lr, path.thp * bsdfProperties.emission * misWeight,
                    path.useHybridShift, path.russianRoulettePdf, misWeight, lightPdf, (uint)LightSampleType::Emissive, path.pathReservoir, path.enableRandomReplay);
#endif
                // daqi: if current escaped vertex has path.length >= 2, then it can be used as a rcVertex
                if (selectedCurrentPath&& path.useHybridShift&& path.length >= 2 && path.length < path.pathBuilder.rcVertexLength)
                {
                    // insert path flags

                    // daqi: ideally, this should use a smaller nearFieldDistance than the default threshold
                    bool isFarField = length(sd.posW - path.origin) >= params.nearFieldDistance;
                    bool isLastVertexAcceptableForRcPrev = path.isLastVertexClassifiedAsRough;

                    if (!(params.localStrategyType & (uint)LocalStrategy::DistanceCondition && !isFarField || params.localStrategyType & (uint)LocalStrategy::RoughnessCondition && !isLastVertexAcceptableForRcPrev))
                    {
                        if (path.isReplayForHybridShift) // non-invertible case
                        {
                            path.L = 0.f;
                        }
                        else
                        {
                            // we found an RC vertex!
                            // set rcVertexLength to current length (this will make rcVertexLength = reseroivr.pathLength + 1)
                            float3 disp = path.origin - sd.posW;
                            float geometryFactor = abs(dot(sd.faceN, sd.V)) / dot(disp, disp);

                            path.pathBuilder.markEscapeVertexAsRcVertex(params, path.length, path.pathReservoir, path.hit, path.isDelta(), path.isTransmission(), path.isSpecularBounce(), lightPdf, (uint)LightSampleType::Emissive, bsdfProperties.emission, float3(0.f), path.prevScatterPdf, geometryFactor);
                        }
                    }
                }
            }
        }

        // Terminate after scatter ray on last vertex has been processed.
        if (hasFinishedSurfaceBounces(path) || terminateRandomReplayForEscape)
        {
            path.terminate();
            return;
        }

        // daqi: save as previous path origin to compute distance between vertices
        float3 prevPathOrigin = path.origin;

        // Compute origin for rays traced from this path vertex.
        path.origin = sd.computeRayOrigin();

        // Determine if BSDF has non-delta lobes.
        const uint lobeTypes = mi.getLobeTypes(sd);
        const bool hasNonDeltaLobes = (lobeTypes & (uint)LobeType::NonDelta) != 0;

        // Check if we should apply NEE.
        const bool applyNEE = kUseNEE && hasNonDeltaLobes;

        // daqi: we don't use the integrated ScreenSpaceReSTIR as inlinepathtracer does, instead, we call ScreenSpaceReSTIRPass
        // therefore, functions with applyScreenSpaceReSTIR as condition are removed
        // Check if sample from screen space ReSTIR should be applied instead of NEE.
        //const bool applyScreenSpaceReSTIR = kUseScreenSpaceReSTIR && isPrimaryHit && !isVolumeHit && supportsNEE;

        // Check if lights should be sampled.
        bool sampleLights = applyNEE;

        // daqi: when doing random number replay, we will terminate the path when the length reaches the base path length and
        // when the path types match. In this case, if the base path is a NEE path (as opposed to an escaped path), we should terminate when we
        // find that offset path can also be an NEE path
        bool terminateRandomReplayForNEE = path.enableRandomReplay && path.length == path.randomReplayLength && path.randomReplayIsNEE;

        bool is_rcVertex = false;
        
        bool isFarField = length(path.origin - prevPathOrigin) >= params.nearFieldDistance;

        bool isCurrentVertexClassifiedAsRough = kSeparatePathBSDF ? bsdfProperties.hasRoughComponent(params.specularRoughnessThreshold) : bsdfProperties.classifyAsRough(params.specularRoughnessThreshold);
        bool isLastVertexAcceptableForRcPrev = path.isLastVertexClassifiedAsRough;

        // daqi: if we are not doing a hybrid shift replay, we should check if current vertex satisfy the condition to be used as a rcVertex
        if (!path.isReplayForHybridShift && PathSamplingMode(kPathSamplingMode) != PathSamplingMode::PathTracing)
        {
            bool canConnect = (path.length >= 1 && path.length < path.pathBuilder.rcVertexLength &&
                (!(params.localStrategyType & (uint)LocalStrategy::DistanceCondition && !isFarField ||
                        params.localStrategyType & (uint)LocalStrategy::RoughnessCondition && !(isCurrentVertexClassifiedAsRough && isLastVertexAcceptableForRcPrev))));

            if (!path.useHybridShift && path.length == 1 || path.useHybridShift && canConnect)
            {
                is_rcVertex = true;
                path.pathBuilder.rcVertexHit.initFromHitInfo(path.hit);
                // daqi: save the scatter PDF as cachedJacobian
                path.pathBuilder.cachedJacobian.x = path.prevScatterPdf;
                path.pathBuilder.pathFlags.insertIsDeltaEvent(path.isDelta(), true);
                path.pathBuilder.pathFlags.insertIsTransmissionEvent(path.isTransmission(), true);
                if (kSeparatePathBSDF)
                    path.pathBuilder.pathFlags.insertIsSpecularBounce(path.isSpecularBounce(), true);

                float3 disp = prevPathOrigin - sd.posW;

                // daqi: save geometry term as part of cachedJacobian
                path.pathBuilder.cachedJacobian.z = abs(dot(sd.faceN, sd.V)) / dot(disp, disp);

                // daqi: save the current path length as the rcVertex length
                if (canConnect || !path.useHybridShift)
                {
                    path.pathBuilder.rcVertexLength = path.length;
                }
            }
        }
        else if (PathSamplingMode(kPathSamplingMode) != PathSamplingMode::PathTracing)
        {
            bool invertible = true;
            bool shouldTerminate = false;

            // daqi: check situation where invertibility is violated
            if (path.length >= 1 && path.length <= path.pathBuilder.rcVertexLength - 1)
            {
                if (kSeparatePathBSDF)
                {
                    if (params.localStrategyType & (uint)LocalStrategy::RoughnessCondition)
                    {
                        // method 2
                        //non-invertible if this bounce is an NEE bounce for the base path but the current vertex is not connectible in base path but is connectible in offset path
                        if (terminateRandomReplayForNEE && isCurrentVertexClassifiedAsRough && isLastVertexAcceptableForRcPrev) invertible = false;
                        //non-invertible because current vertex will be assigned as a diffuse bounce by connecting to the reconnection vertex
                        if (path.length == path.pathBuilder.rcVertexLength - 1 && isLastVertexAcceptableForRcPrev) invertible = false;

                        if (params.localStrategyType & (uint)LocalStrategy::DistanceCondition && !isFarField) invertible = true;
                    }
                    else
                    {
                        if (params.localStrategyType & (uint)LocalStrategy::DistanceCondition && isFarField) invertible = false;
                    }
                }
                else
                {
                    if (!(params.localStrategyType & (uint)LocalStrategy::DistanceCondition && !isFarField ||
                        params.localStrategyType & (uint)LocalStrategy::RoughnessCondition && !(/*supportsNEE &&*/ isCurrentVertexClassifiedAsRough && isLastVertexAcceptableForRcPrev)))
                        invertible = false;
                }
            }

            // daqi: if next vertex is rcVertex and the shift is still invertible, then we should terminate
            if (path.length == path.pathBuilder.rcVertexLength - 1 && invertible)
            {
                // not possible to generate a diffuse bounce
                if (params.localStrategyType & (uint)LocalStrategy::RoughnessCondition &&
                        (kSeparatePathBSDF && (path.pathBuilder.pathFlags.decodeIsSpecularBounce(true) ? 
                        bsdfProperties.roughness <= params.specularRoughnessThreshold : 
                        !bsdfProperties.hasRoughComponent(1.f)) ||
                        !kSeparatePathBSDF && !isCurrentVertexClassifiedAsRough))
                {
                    // daqi: invalidate the shift
                    invertible = false;
                }
                // daqi: near field rejection case is checked in computeShiftedIntegrandReconnection in shift.slang
                else
                {
                    shouldTerminate = true;
                }
            }

            if (invertible)
            {
                // daqi: if it is invertible and we should terminate, save the hit information to set up a reconnection
                if (shouldTerminate)
                {
                    path.rcPrevVertexHit = path.hit;
                    path.rcPrevVertexWo = sd.V;
                    path.terminate();
                }
            }
            else //daqi: if the shift is not invertible, we should mark the case, which causes the shift to terminate when it goes back to shift.slang
            {
                invalidateAndTerminateReplayPath(path);
            }

            if (!path.isActive()) return;
        }

        path.setLightSampled(false, false);

        // daqi: if we are doing random number replay, we should only sample the light if we are about to terminate
        if (!(kDisableDirectIllumination && isPrimaryHit))
        {
            // generate kNEESamples light samples
            if (sampleLights && (!path.enableRandomReplay || terminateRandomReplayForNEE))
            {
                // cache (NEE sampling) seed for temporal validation (only possible for non early direction reuse since it uses the cachedRandomSeed slot)
                if (path.length == path.pathBuilder.rcVertexLength)
                {
                    path.pathBuilder.cachedRandomSeed = path.sg.getCurrentSeed();
                }

                LightSample ls;
                bool validSample = true;
                {
                    // Setup path vertex.
                    PathVertex vertex = PathVertex(path.length + 1, sd.posW, sd.faceN, sd.frontFacing);

                    // Determine if upper/lower hemispheres need to be sampled.
                    bool sampleUpperHemisphere = ((lobeTypes & (uint)LobeType::NonDeltaReflection) != 0);
                    if (!kUseLightsInDielectricVolumes && path.isInsideDielectricVolume()) sampleUpperHemisphere = false;
                    bool sampleLowerHemisphere = ((lobeTypes & (uint)LobeType::NonDeltaTransmission) != 0);

                    // Sample a light.

                    validSample = generateLightSample(vertex, sampleUpperHemisphere, sampleLowerHemisphere, path.sg, ls);

                    path.setLightSampled(sampleUpperHemisphere, sampleLowerHemisphere);
                }

                if (validSample)
                {
                    // Apply MIS weight.
                    float misWeight = 1.f;
                    float scatterPdf = 0.f;

                    if (kUseMIS && ls.lightType != (uint)LightSampleType::Analytic)
                    {
                        scatterPdf = mi.evalPdf(sd, ls.dir, kUseBSDFSampling);
                        misWeight *= evalMIS(1, ls.pdf, 1, scatterPdf);
                    }
                    ls.Li *= misWeight;

                    float3 weight = mi.eval(sd, ls.dir, path.sg);

                    float3 Lr = weight * ls.Li * path.getCurrentThp();

                    if (any(Lr > 0.f))
                    {
                        const Ray ray = ls.getVisibilityRay();
                        bool visible = traceVisibilityRay(ray);
                        if (visible)
                        {
                            if (!path.enableRandomReplay || terminateRandomReplayForNEE)
                                path.L += Lr;

                            if (ls.lightType == (uint)LightSampleType::Analytic && ls.pdf == 0.f)
                            {
                                ls.pdf = getAnalyicSelectionProbability(); // analytic light doesn't have a solid angle PDF.
                            }

                            // daqi: here we are adding the path terminated with an NEE event
                            // if we have enabled random replay, we know that we are going to use this path

                            if (PathSamplingMode(kPathSamplingMode) != PathSamplingMode::PathTracing)
                            {
                                if (is_rcVertex)
                                {
                                    weight = 1.f;
                                }
#if BPR
                                if (!is_rcVertex)
                                {
                                    path.rcVertexPathTreeIrradiance += weight * ls.Li * path.thp;
                                }

                                bool selected = path.pathBuilder.addNeeVertex(params, path.length, ls.dir, Lr,
                                    is_rcVertex ? weight * ls.Li * path.thp : path.rcVertexPathTreeIrradiance, path.useHybridShift,
                                    path.russianRoulettePdf, misWeight, ls.pdf, ls.lightType, path.pathReservoir, path.enableRandomReplay);
#else
                                bool selected = path.pathBuilder.addNeeVertex(params, path.length, ls.dir, Lr, weight * ls.Li * path.thp, path.useHybridShift,
                                    path.russianRoulettePdf, misWeight, ls.pdf, ls.lightType, path.pathReservoir, path.enableRandomReplay);
#endif
                            }
                        }
                    }
                }
            }
            else
                // daqi: for random number replay, we should skip the random numbers for NEE if we should not terminate on current bounce
            {
                if (path.enableRandomReplay && sampleLights)
                {
                    bool sampleUpperHemisphere = ((lobeTypes & (uint)LobeType::NonDeltaReflection) != 0);
                    if (!kUseLightsInDielectricVolumes && path.isInsideDielectricVolume()) sampleUpperHemisphere = false;
                    bool sampleLowerHemisphere = ((lobeTypes & (uint)LobeType::NonDeltaTransmission) != 0);
                    path.setLightSampled(sampleUpperHemisphere, sampleLowerHemisphere);
                }

                skipLightSampleRandomNumbers(path.sg);
            }
        }

        // daqi: terminate the path if the bounce of random replay reaches the desired bounce and the base path is an NEE path
        if (terminateRandomReplayForNEE)
        {
            path.terminate();
            return;
        }

        // Russian roulette to terminate paths early.
        // TODO: check if this is handled correctly in ReSTIR PT
        if (kUseRussianRoulette && path.length >= 1)
        {
            if (path.enableRandomReplay)
            {
                sampleNext1D(path.sg);
            }
            else
            {
                if (terminatePathByRussianRoulette(path)) return;
            }
        }

        // Temporary keep path throughput from before the scatter event.
        float3 prevThp = path.getCurrentThp();

        if (path.length == 0)
        {
            // daqi: save current random seed, this is required to do random number replay to construct a path
            path.pathReservoir.initRandomSeed = path.sg.getCurrentSeed();
        }

        // Generate the next path segment or terminate.
        bool valid = generateScatterRay(sd, mi, path);

        // forbid current vertex being rcVertex
        if (kSeparatePathBSDF && params.localStrategyType & (uint)LocalStrategy::RoughnessCondition)
        {
            bool seenAsConnectible = !path.isSpecularBounce() || bsdfProperties.roughness > params.specularRoughnessThreshold;

            if (path.isReplayForHybridShift && seenAsConnectible && isLastVertexAcceptableForRcPrev && path.length >= 1)
            {
                // check if near field rejection is satisfied
                if (isFarField || !(params.localStrategyType & (uint)LocalStrategy::DistanceCondition))
                {
                    // non-invertible
                    invalidateAndTerminateReplayPath(path);
                }
            }
            else if (!path.isReplayForHybridShift && path.useHybridShift && !seenAsConnectible)
            {
                if (is_rcVertex)
                {
                    is_rcVertex = false;
                    path.pathBuilder.rcVertexLength = kMaximumPathLength; // reset
                }
            }
            if (path.useHybridShift) isCurrentVertexClassifiedAsRough = seenAsConnectible;
        }

        // cache seed for temporal validation (only possible for non early direction reuse since it uses the cachedRandomSeed slot)
        if (path.length == path.pathBuilder.rcVertexLength)
        {
            path.pathBuilder.cachedRandomSeed = path.sg.getCurrentSeed();
        }

        // daqi: save the incoming direction on rcVertex
        if (is_rcVertex && valid && (int(path.length > 1) == 0 || !BPR))
        {
            path.pathBuilder.rcVertexWi[0] = path.dir;
        }

        path.isLastVertexClassifiedAsRough = isCurrentVertexClassifiedAsRough;

        // if (kOutputNRDData && !path.enableRandomReplay)
        // {
        //     const uint2 pixel = path.getPixel();

        //     if (gSppId == 0)
        //     {
        //         setNRDPrimaryHitEmission(outputNRD, kUseNRDDemodulation, path, pixel, isPrimaryHit, attenuatedEmission);
        //         setNRDPrimaryHitReflectance(outputNRD, kUseNRDDemodulation, path, pixel, isPrimaryHit, sd);
        //     }

        //     setNRDSampleHitDist(path); // this will be overriden if ReSTIR is done
        //     setNRDSampleEmission(kUseNRDDemodulation, path, isPrimaryHit, attenuatedEmission); // this should be the same for every sample (unless in volume rendering)
        //     setNRDSampleReflectance(kUseNRDDemodulation, path, isPrimaryHit, sd); // this will be overriden in ReSTIR mode
        // }

        if (!path.isActive()) return;

        // Check if this is the last path vertex.
        const bool isLastVertex = hasFinishedSurfaceBounces(path);

        // Terminate if this is the last path vertex and light sampling already completely sampled incident radiance.
        if (kUseNEE && !kUseMIS && isLastVertex && path.isLightSamplable()) valid = false;

        // Terminate caustics paths.
        if (kDisableCaustics && path.getBounces(BounceType::Diffuse) > 0 && path.isSpecular()) valid = false;

        if (!valid)
        {
            path.terminate();
        }
    }

    /** Trace active path to find the next path vertex.
        \param[in,out] path The path state.
    */
    void nextVertex(inout PathState path)
    {
        // Setup ray.
        Ray ray = Ray(path.origin, path.dir, 0.f, kRayTMax);
        // Ray ray = path.getScatterRay();

        // logTraceRay(PixelStatsRayType::ClosestHit);
        float hitT;
        SceneRayQuery<kUseAlphaTest> sceneRayQuery;
        HitInfo hit = sceneRayQuery.traceRay(ray, hitT);

        if (hit.isValid())
        {
            // Store hit info.
            path.setHit(hit);
            path.length++;
            path.sceneLength += float16_t(hitT);
        }
        else
        {
            path.clearHit();
            path.sceneLength = float16_t(kNRDInvalidPathLength);
        }
    }
    void setDataBeforeTermination(inout HitInfo rcPrevHit, inout float3 rcPrevHitWo)
    {
        rcPrevHit = HitInfo();
        rcPrevHitWo = float3(0);
    }

    float3 traceRandomReplayPathHybridSimple(HitInfo hit, ShadingData sd, Ray ray, ReSTIRPathFlags pathFlags,
        uint initRandomSeed, inout HitInfo rcPrevHit, inout float3 rcPrevHitWo)
    {
        PathState path;
        bool isRcVertexEscapedVertex = pathFlags.pathLength() + 1 == pathFlags.rcVertexLength();
        generateRandomReplayPath(path, hit, ray, initRandomSeed, pathFlags.pathLength(), pathFlags.lastVertexNEE(), isRcVertexEscapedVertex);
        path.useHybridShift = true;
        path.isReplayForHybridShift = true;
        path.pathBuilder.rcVertexLength = pathFlags.rcVertexLength();

        setDataBeforeTermination(rcPrevHit, rcPrevHitWo);

        path.origin = sd.computeRayOrigin();

        // this is also applicable for random number reuse
        path.pathBuilder.pathFlags.flags = 0;
        path.pathBuilder.pathFlags.transferSpecularBounceInformation(pathFlags);

        // set up the two scatter directions (or half vectors) for reuse
        // Create texture sampler.
        let lod = createTextureSampler(path, path.length == 0);

        // Create BSDF instance and query its properties.
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, lod);

        generateReplayPrimaryScatterRay(path, sd, mi);
        if (path.isActive()) nextVertex(path);
        else
        {
            return 0.f;
        }

        while (path.isActive() && path.isHit())
        {
            // Volume scattering is ignored
            // Handle surface hit
            if (path.isActive())
            {
                if (path.isHit())
                {
                    handleHit(path);
                }
            }

            // Move to the next path vertex.
            if (path.isActive() && path.isHit()) nextVertex(path);
        }

        // Handle the miss and terminate path.
        if (path.isActive())
        {
            handleMiss(path);

            // non-invertible: path length doesn't match
            if (path.length != pathFlags.pathLength())
            {
                return 0.f;
            }
        }

        rcPrevHit = HitInfo();

        float3 L = 1.f;

        if (pathFlags.rcVertexLength() <= pathFlags.pathLength() || isRcVertexEscapedVertex)
        {
            rcPrevHit = path.rcPrevVertexHit;
            rcPrevHitWo = path.rcPrevVertexWo;
            L = path.getCurrentThp();
        }
        else // this branch is the case where rcVertex does not exist (or infinitely far)
        {
            L = path.L;
        }

        return L;
    }


    void traceTemporalUpdate(ShadingData rcPrevSd, inout PathReservoir tempPathReservoir)
    {
        int rcVertexLength = tempPathReservoir.pathFlags.rcVertexLength();
        ShadingData rcVertexSd = loadShadingDataWithPrevVertexPosition(
            tempPathReservoir.rcVertexHit.getHitInfo(), float3(0.0) ,rcPrevSd.posW);
        
        // Create BSDF instance and query its properties.
        const IMaterialInstance rcVertexMi = gScene.materials.getMaterialInstance(rcVertexSd, ExplicitLodTextureSampler(0.0));
        PathState path;

        //rcVertex is NEE
        if (tempPathReservoir.pathFlags.lastVertexNEE() && tempPathReservoir.pathFlags.pathLength() == rcVertexLength)
        {
            path = {};
            path.length = rcVertexLength;
            // call light sampling function
            LightSample ls;
            bool validSample = true;
            {
                uint lobes = rcVertexMi.getLobeTypes(rcVertexSd);
                // Setup path vertex.
                PathVertex vertex = PathVertex(path.length + 1, rcVertexSd.posW, rcVertexSd.faceN, rcVertexSd.frontFacing);

                // Determine if upper/lower hemispheres need to be sampled.
                bool sampleUpperHemisphere = ((lobes & (uint)LobeType::NonDeltaReflection) != 0);
                bool sampleLowerHemisphere = ((lobes & (uint)LobeType::NonDeltaTransmission) != 0);

                path.sg = SampleGenerator(tempPathReservoir.rcRandomSeed);
                validSample = generateLightSample(vertex, sampleUpperHemisphere, sampleLowerHemisphere, path.sg, ls);
            }

            bool visible = true;
            if (validSample)
            {
                const Ray ray = ls.getVisibilityRay();
                visible = traceVisibilityRay(ray);


                if (ls.lightType == (uint)LightSampleType::Analytic && ls.pdf == 0.f)
                {
                    ls.pdf = getAnalyicSelectionProbability(); // analytic light doesn't have a solid angle PDF.
                }
            }

            if (validSample && visible)
            {
                tempPathReservoir.rcVertexWi[0] = ls.dir;
                tempPathReservoir.rcVertexIrradiance[0] = ls.Li * ls.pdf;
                tempPathReservoir.pathFlags.insertLightType(ls.lightType);
                tempPathReservoir.lightPdf = ls.pdf;
            }
            else tempPathReservoir.rcVertexIrradiance[0] = 0.f;
        }
        else
        {
            Ray emptyRay = Ray(float3(0.f), float3(0.f), 0.f, kRayTMax);

            // should always be false in this case
            bool isRcVertexEscapedVertex = false;
            generateRandomReplayPath(path, tempPathReservoir.rcVertexHit.getHitInfo(), emptyRay, tempPathReservoir.rcRandomSeed, tempPathReservoir.pathFlags.pathLength(), tempPathReservoir.pathFlags.lastVertexNEE(), isRcVertexEscapedVertex);
            path.length = rcVertexLength;
            path.useHybridShift = false;
            path.isReplayForHybridShift = false;

            uint lobes = rcVertexMi.getLobeTypes(rcVertexSd);
            bool sampleUpperHemisphere = ((lobes & (uint)LobeType::NonDeltaReflection) != 0);
            if (!kUseLightsInDielectricVolumes && path.isInsideDielectricVolume()) sampleUpperHemisphere = false;
            bool sampleLowerHemisphere = ((lobes & (uint)LobeType::NonDeltaTransmission) != 0);
            path.setLightSampled(sampleUpperHemisphere, sampleLowerHemisphere);

            // start from path length
            float3 scatterDir = tempPathReservoir.rcVertexWi[0];
            path.pathBuilder.rcVertexLength = rcVertexLength;
            path.origin = rcVertexSd.computeRayOrigin(!tempPathReservoir.pathFlags.decodeIsTransmissionEvent(false));

            path.pathBuilder.pathFlags.transferDeltaInformation(tempPathReservoir.pathFlags);
            path.pathBuilder.pathFlags.transferTransmissionInformation(tempPathReservoir.pathFlags);
            path.pathBuilder.pathFlags.transferSpecularBounceInformation(tempPathReservoir.pathFlags);
            path.pathReservoir.rcVertexIrradiance[0] = 0.f;

            generateReplayPrimaryScatterRay(path, rcVertexSd, rcVertexMi, scatterDir);
            path.sg = SampleGenerator(tempPathReservoir.rcRandomSeed);
            if (path.isActive()) nextVertex(path);

            while (path.isActive() && path.isHit())
            {
                // Volume scattering is ignored
                // Handle surface hit 
                if (path.isActive())
                {
                    if (path.isHit())
                    {
                        handleHit(path);
                    }
                }

                // Move to the next path vertex.
                if (path.isActive() && path.isHit()) nextVertex(path);
            }

            // Handle the miss and terminate path.
            if (path.isActive())
            {
                handleMiss(path);
            }

            // unlike traceRandomReplayPath(), we don't directly copy the path.pathReservoir.
            // this is because we start at path.length == 2, we can also terminate early,
            // so pathReservoir won't record enough information for a complete path reservoir
            // so we need to manually copy some members we need later
            // this cannot be replaced by pathBuilder because of escapedRcVertex not setting pathBuilder.rcVertexHit (TODO: refactor)
            tempPathReservoir.rcVertexIrradiance[0] = path.pathReservoir.rcVertexIrradiance[0];
            tempPathReservoir.lightPdf = path.pathReservoir.lightPdf;
            tempPathReservoir.pathFlags.insertLightType(path.pathReservoir.pathFlags.lightType());
        }
    }



    /** Handle the case when a scatter ray misses the scene.
        \param[in,out] path The path state.
    */
    void handleMiss(inout PathState path)
    {
        path.terminate();
    }

    /** Generates a new scatter ray using BSDF importance sampling.
        \param[in] sd Shading data.
        \param[in] mi Material instance at the shading point.
        \param[in,out] path The path state.
        \return True if a ray was generated, false otherwise.
    */
    bool generateScatterRay(const ShadingData sd, const IMaterialInstance mi, inout PathState path)
    {
        BSDFSample result;
        bool valid = mi.sample(sd, path.sg, result, kUseBSDFSampling);
        if (valid) valid = generateScatterRay(result, sd, mi, path);

        // Mark the path as valid only if it has a non-zero throughput.
        valid = any(path.thp > 0.f);

        // Add to the path gaph.
        // TODO: Handle specular/delta/transmission events.
        if (valid)
        {
            if (path.length <= path.pathBuilder.rcVertexLength)
                path.recordPrefixThp();
        }

        return true;
    }

    /** Generates a new scatter ray given a valid BSDF sample.
        \param[in] bs BSDF sample (assumed to be valid).
        \param[in] sd Shading data.
        \param[in] mi Material instance at the shading point.
        \param[in,out] path The path state.
        \return True if a ray was generated, false otherwise.
    */
    bool generateScatterRay(const BSDFSample bs, const ShadingData sd, const IMaterialInstance mi, inout PathState path)
    {
        const bool isTriangleHit = path.hit.getType() == HitType::Triangle;
        const bool isCurveHit = kUseCurves && (path.hit.getType() == HitType::Curve);
        const bool isHairMaterial = kUseHairMaterial && (sd.mtl.getMaterialType() == MaterialType::Hair);
        // TODO: Decouple geometry from the material.
        const bool isCurvePolyTubeHit = isTriangleHit && isHairMaterial;

        path.dir = bs.wo;
        updatePathThroughput(path, bs.weight);
        path.pdf = bs.pdf;

        path.clearEventFlags();

        // Handle reflection events.
        if (bs.isLobe(LobeType::Reflection))
        {
            // We classify specular events as diffuse if the roughness is above some threshold.
            float roughness = mi.getProperties(sd).roughness;
            bool isDiffuse = bs.isLobe(LobeType::DiffuseReflection) || roughness > params.specularRoughnessThreshold;

            if (isDiffuse)
            {
                path.incrementBounces(BounceType::Diffuse);
            }
            else
            {
                path.incrementBounces(BounceType::Specular);
                path.setSpecular();
            }
        }

        // Handle delta events.
        if (bs.isLobe(LobeType::Delta))
        {
            path.setDelta();
        }

        // Handle transmission events.
        if (bs.isLobe(LobeType::Transmission))
        {
            path.incrementBounces(BounceType::Transmission);
            path.setTransmission();

            if (isCurveHit)
            {
                // No need to offset the origin in this case.
            }
            else if (isCurvePolyTubeHit)
            {
                // For curves tessellated into poly-tubes, we make sure that the origin is on the same side as a scatter ray direction
                // so there is no self-intersection.
                path.origin = sd.posW - sd.frame.N * sd.curveRadius * 2.1f;
            }
            else
            {
                // Compute ray origin for next ray segment.
                path.origin = sd.computeRayOrigin(false);

                // Update interior list and inside volume flag.
                if (!sd.mtl.isThinSurface())
                {
                    uint nestedPriority = sd.mtl.getNestedPriority();
                    path.interiorList.handleIntersection(sd.materialID, nestedPriority, sd.frontFacing);
                    path.setInsideDielectricVolume(!path.interiorList.isEmpty());
                }
            }
        }

        // Save the normal used for NEE. This is needed for MIS.
        path.normal = sd.getOrientedFaceNormal();

        // Mark the path as valid only if it has a non-zero throughput.
        bool valid = any(path.thp > 0.f);

        return valid;
    }

    /** Update the path throughouput.
        \param[in,out] path Path state.
        \param[in] weight Vertex throughput.
    */
    void updatePathThroughput(inout PathState path, const float3 weight)
    {
        path.thp *= weight;
    }

    /** Finalize the path state before writing to the output buffer.
    */
    void finalize(inout PathState path)
    {
        path.pathBuilder.finalize(path.pathReservoir);
    }

    /** Write path contribution to output buffer.
    */
    void writeOutput(PathState path, inout PathReservoir giReservoir, int sampleId)
    {
        // Log path length.
        // logPathLength(getTerminatedPathLength(path));

        const uint2 pixel = path.getPixel();

        const uint reservoirIdx = params.getReservoirOffset(pixel);

        static const uint itersPerShaderPass = PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing ? kSamplesPerPixel : kCandidateSamples;

        if (itersPerShaderPass == 1)
        {
            float3 L = 0.f;

            if (useDirectLighting) L += path.LDeltaDirect;

            if (PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing)
                L += path.L;
            else if (PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathReuse)
            {
                path.pathReservoir.weight = 1.f;
                if (isLastRound)
                {
                    float3 color = path.pathReservoir.F + path.pathReservoir.cachedJacobian;
                    if (any(isinf(color) || isnan(color))) color = 0.f;
                    L += color;
                }
            }
            else
            {
                path.pathReservoir.finalizeRIS();

                if (isLastRound)
                {
                    // Write color directly to frame buffer.
                    float3 color = path.pathReservoir.F * path.pathReservoir.weight;

                    if (any(isinf(color) || isnan(color))) color = 0.f;

                    L += color;
                }
            }

            if (useDirectLighting && (PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing || isLastRound))
            {
                L += directLighting[pixel].rgb;
            }

            if (any(isinf(L) || isnan(L))) L = 0.f;

            if (PathSamplingMode(kPathSamplingMode) != PathSamplingMode::PathTracing)
                L /= kSamplesPerPixel;

            if (PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing || kSamplesPerPixel == 1 || gSppId == 0 )
                outputColor[pixel] = float4(L, 1.f);
            else
                outputColor[pixel] += float4(L, 1.f);

            if (PathSamplingMode(kPathSamplingMode) != PathSamplingMode::PathTracing)
                outputReservoirs[reservoirIdx] = path.pathReservoir;
        }
        else
        {
            if (PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing)
            {
                float3 L = 0.f;
                if (sampleId == 0)
                {
                    L = path.L / kSamplesPerPixel;
                }
                else
                {
                    L = giReservoir.F;
                    L += path.L / kSamplesPerPixel;
                }
                if (useDirectLighting && sampleId == kSamplesPerPixel - 1) L += path.LDeltaDirect;

                if (any(isinf(L) || isnan(L))) L = 0.f;

                if (sampleId == kSamplesPerPixel - 1)
                {
                    if (useDirectLighting)
                    {
                        L += directLighting[pixel].rgb;
                        if (any(isnan(L) || isinf(L))) L = 0.f;
                    }

                    outputColor[pixel] = float4(L, 1.f);
                }
                else giReservoir.F = L;
            }
            else
            {

                if (sampleId == 0)
                {
                    giReservoir = path.pathReservoir; // we are the first one
                }
                else
                {
                    if (giReservoir.mergeInSamplePixel(path.pathReservoir, path.sg))
                    {
                        giReservoir.F = path.pathReservoir.F;
                    }
                }

                if (sampleId == kCandidateSamples - 1) // last sample
                {
                    float3 L = 0.f;
                    if (useDirectLighting) L += path.LDeltaDirect;

                    giReservoir.finalizeRIS();
                    if (isLastRound)
                    {
                        float3 color = giReservoir.F * giReservoir.weight;

                        if (any(isinf(color) || isnan(color))) color = 0.f;
                        L += color;
                    }

                    if (useDirectLighting && isLastRound)
                    {
                        L += directLighting[pixel].rgb;
                        if (any(isnan(L) || isinf(L))) L = 0.f;
                    }

                    L /= kSamplesPerPixel;

                    if (kSamplesPerPixel == 1 || gSppId == 0)
                        outputColor[pixel] = float4(L, 1.f);
                    else
                        outputColor[pixel] += float4(L, 1.f);

                    outputReservoirs[reservoirIdx] = giReservoir;
                }
            }
        }

        // if (kOutputNRDData && PathSamplingMode(kPathSamplingMode) == PathSamplingMode::PathTracing)
        // {
            
        // }
    }


    // generate random replay path
    void generateRandomReplayPath(out PathState path, HitInfo hit, Ray ray, uint randomSeed, int randomReplayLength, bool isLastVertexNEE, bool isRcVertexEscapedVertex)
    {
        path = {};
        path.L = 0.f;
        path.setActive();
        path.thp = float3(1.f);
        path.prefixThp = float3(1.f);
        path.rcVertexPathTreeIrradiance = float3(0.f);

        path.enableRandomReplay = true;
        path.useHybridShift = ShiftMapping(kShiftStrategy) == ShiftMapping::Hybrid;
        path.setHit(hit);

        path.origin = ray.origin;
        path.dir = ray.dir;

        path.sg = SampleGenerator(randomSeed); 

        path.randomReplayIsNEE = isLastVertexNEE && !isRcVertexEscapedVertex;
        path.randomReplayIsEscaped = !isLastVertexNEE && !isRcVertexEscapedVertex;
        path.randomReplayLength = randomReplayLength;

        path.pathReservoir.init();
    }

    void generateReplayPrimaryScatterRay(inout PathState path, 
        ShadingData sd, 
        const IMaterialInstance mi,
        float3 dir = 0.f)
    {
        BSDFProperties bsdfProperties = mi.getProperties(sd);
        // Generate the next path segment or terminate.
        bool valid = true;

        if (all(dir == 0.f))
        {
            valid = generateScatterRay(sd, mi, path);
        }
        else // generate with given direction
        {
            valid = generateScatterRayGivenDirection(sd, mi, dir, path);
        }

        if (!valid)
        {
            path.terminate();
        }
        else
        {
            path.isLastVertexClassifiedAsRough =
                kSeparatePathBSDF ? (!path.isSpecularBounce() || bsdfProperties.roughness > params.specularRoughnessThreshold) : bsdfProperties.classifyAsRough(params.specularRoughnessThreshold);
        }
    }
    
    // TODO: support BySampledBSDF replay
    bool generateScatterRayGivenDirection(const ShadingData sd, 
        const IMaterialInstance mi, float3 dir, inout PathState path)
    {
        bool isCurveHit = path.hit.getType() == HitType::Curve;

        // Generate a BSDF sample.
        bool valid = true;
        BSDFSample result;

        bool isDeltaEvent = path.pathBuilder.pathFlags.decodeIsDeltaEvent(path.length < 1);
        bool isSpecularBounce = path.pathBuilder.pathFlags.decodeIsSpecularBounce(path.length < 1);

        if (isDeltaEvent) valid = false; // not allowing delta event to be shifted by directional reuse

        if (valid)
        {
            float pdfAll = 0.f; // pdf with all BSDF

            {
                result.wo = dir;

                // uint allowedBSDFFlags = getAllowedBSDFFlags(isSpecularBounce);

                result.weight = mi.eval(sd, dir, path.sg);
                
                if (kUseBSDFSampling)
                {
                    // scatterPdf = 
                    // this is single pdf
                    result.pdf = mi.evalPdf(sd, result.wo, false);
                    // evalPdfBSDF(sd, result.wi, pdfAll, allowedBSDFFlags, false);
                }
                else
                {
                    result.pdf = dot(sd.getOrientedFaceNormal(), result.wo) / M_PI;
                }

                result.weight /= result.pdf;

                if (result.pdf <= 0.f)
                {
                    result.weight = 0.f;
                }
            }

            path.dir = result.wo;

            // add to path buffer
            // also multiply pdf
            path.thp *= result.weight;

            path.pdf = pdfAll;

            if (path.length == path.pathBuilder.rcVertexLength)
            {
                path.pathBuilder.cachedJacobian.y = result.pdf;
            }

            // daqi: record the scatter pdf, we will need to use that later for the cachedJacobian
            path.prevScatterPdf = result.pdf;

#if _USE_LEGACY_SHADING_CODE
            // Legacy BRDF code sometimes returns infinite PDF values.
            // We clamp them to avoid getting NaNs from the evalMIS function.
            path.pdf = min(path.pdf, 1e30f);
#endif

            path.clearEventFlags();

            // daqi: if we use direction reuse, then base and offset path reflection/transmission type is allowed to be different
            bool isTransmissionEvent = dot(sd.getOrientedFaceNormal(), result.wo) < 0;

            // daqi: set delta/transmission path flags. we don't care about other path flags since our resampling doesn't depend on the sampled BSDF components
            // Handle transmission events.
            if (isTransmissionEvent)
            {
                // Compute ray origin for next ray segment.
                path.origin = sd.computeRayOrigin();
                path.setTransmission();

                // Update interior list and inside volume flag.
                if (!sd.mtl.isThinSurface())
                {
                    uint nestedPriority = sd.mtl.getNestedPriority();
                    path.interiorList.handleIntersection(sd.materialID, nestedPriority, sd.frontFacing);
                    path.setInsideDielectricVolume(!path.interiorList.isEmpty());
                }
            }

            if (isSpecularBounce)
            {
                path.setSpecularBounce();
            }

            // Save the shading normal. This is needed for MIS.
            path.normal = sd.getOrientedFaceNormal();

            // Mark the path as valid only if it has a non-zero throughput.
            valid = any(path.thp > 0.f);

            // Add to the path gaph.
            // TODO: Handle specular/delta/transmission events.
            if (valid)
            {
                if (path.length <= path.pathBuilder.rcVertexLength)
                    path.recordPrefixThp();
            }
        }

        return valid;
    }

    // function to trace a path using random number replay
    float3 traceRandomReplayPath(HitInfo hit, ShadingData sd, ShadingData srcSd, Ray ray, inout PathReservoir tempPathReservoir)
    {
        PathState path;
        generateRandomReplayPath(path, hit, ray, tempPathReservoir.initRandomSeed, tempPathReservoir.pathFlags.pathLength(), tempPathReservoir.pathFlags.lastVertexNEE(), false);
        path.isReplayForHybridShift = false;

        path.origin = sd.computeRayOrigin();

        // set up the two scatter directions (or half vectors) for reuse
        // Create texture sampler.
        let lod = createTextureSampler(path, path.length == 0);

        // Create BSDF instance and query its properties.
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, lod);

        generateReplayPrimaryScatterRay(path, sd, mi);

        if (path.isActive()) nextVertex(path);

        float randomReplayProb = 1.f;

        while (path.isActive() && path.isHit())
        {
            // Handle surface hit 
            if (path.isActive())
            {
                if (path.isHit())
                {
                    handleHit(path);
                }
            }

            // Move to the next path vertex.
            if (path.isActive() && path.isHit()) nextVertex(path);
        }

        // Handle the miss and terminate path.
        if (path.isActive())
        {
            handleMiss(path);
        }

        // we should copy out the pathReservoir, as it contains information like rcVertex which will be needed for MIS
        tempPathReservoir = path.pathReservoir;

        return path.L;
    }

    /** Handle hits on dielectrics.
        \return True if this is an valid intersection, false if it is rejected.
    */
    bool handleNestedDielectrics(inout ShadingData sd, inout PathState path)
    {
        // Check for false intersections.
        uint nestedPriority = sd.mtl.getNestedPriority();
        if (!path.interiorList.isTrueIntersection(nestedPriority))
        {
            // If it is a false intersection, we reject the hit and continue the path
            // on the other side of the interface.
            // If the offset position is not quite large enough, due to self-intersections
            // it is possible we repeatedly hit the same surface and try to reject it.
            // This has happened in a few occasions with large transmissive triangles.
            // As a workaround, count number of rejected hits and terminate the path if too many.
            if (path.rejectedHits < kMaxRejectedHits)
            {
                path.rejectedHits++;
                path.interiorList.handleIntersection(sd.materialID, nestedPriority, sd.frontFacing);
                path.origin = sd.computeRayOrigin(false);
                path.length--;
            }
            else
            {
                path.terminate();
            }
            return false;
        }

        // Compute index of refraction for medium on the outside.
        sd.IoR = computeOutsideIoR(path.interiorList, sd.materialID, sd.frontFacing);

        return true;
    }
};
