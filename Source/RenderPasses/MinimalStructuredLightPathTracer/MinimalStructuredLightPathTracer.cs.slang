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
//import GeometricShiftmapping;
import ProjectorLight;
import ProjectorPatterns.ProjectorPatternInterface;
import ProjectorPatterns.PeriodicPattern;
import ProjectorPatterns.XORPattern;
import ProjectorPatterns.GrayPattern;
// import ProjectorPatterns.OTBitFlipPattern;
import ProjectorPatterns.ArbitraryAntitheticPattern;
import ProjectorPatterns.CheckerboardPattern;


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

float3 evalProjectedLightContribution(
    const ShadingData sd, const ProjectorLight light, 
    const IMaterialInstance mi, inout SampleGenerator sg
)
{
    ProjectorSample ls = evalProjectorLight(light, sd.posW);
    bool V = traceVisibilityRay(sd.computeRayOrigin(), ls.wi, ls.distance);

    if (!ls.valid || !V) return 0.0f;
    float G = 1.0 / (ls.distance * ls.distance);

    float3 L = mi.eval(sd, ls.wi, sg) * ls.radiance * G;
    return L;
}

float3 evalProjectedLightContributionAntithetic(
    const ShadingData sdRef, const ShadingData sdPrev, 
    const ProjectorLight light, float2 uvShift,
){
    // ------------------------------------------------------------
    // (1) Find the reference UV corresponding to sdRef.posW
    // ------------------------------------------------------------
    float2 uvRef;
    if (!worldToProjectorUV(light, sdRef.posW, uvRef))
        return 0.0;

    // ------------------------------------------------------------
    // (2) Shift to the antithetic UV
    // ------------------------------------------------------------
    float2 uvAnti = uvRef + uvShift;

    // Optional: reject if outside [0,1]^2.
    if (any(uvAnti < 0.0) || any(uvAnti > 1.0))
        return 0.0;

    // ------------------------------------------------------------
    // (3) Generate projector ray through shifted UV
    // ------------------------------------------------------------
    float3 projRayDirW;
    if (!projectorUVToWorldRay(light, uvAnti, projRayDirW))
        return 0.0;

    // ------------------------------------------------------------
    // (4) Trace from projector center into the scene
    // ------------------------------------------------------------
    float antiHitT;
    HitInfo antiHit = traceRay(light.positionW, projRayDirW, antiHitT);
    if (!antiHit.isValid())
        return 0.0;

    // ------------------------------------------------------------
    // (5) Load shading/material at the antithetic hit point
    // ------------------------------------------------------------
    ShadingData sdAnti = loadShadingData(antiHit, sdPrev.posW, projRayDirW);
    IMaterialInstance miAnti = gScene.materials.getMaterialInstance(
        sdAnti,
        ExplicitLodTextureSampler(0.f)
    );
}


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
        // return sd0.posW;

        ProjectorLight light;
        light.positionW = laserOrigin;// + float3(0.3, 0.0, 0.0);
        light.dirW = laserDirection;
        float3 up = float3(0.0, 1.0, 0.0);
        float3 f = laserDirection;

        // Remove forward component from up
        float3 u = up - dot(up, f) * f;
        u = normalize(u);

        // Right-handed basis
        float3 r = normalize(cross(f, u));

        // Recompute clean orthogonal up
        u = cross(r, f);

        light.upW = u;
        light.rightW = r;
        light.tanHalfFovX = 0.2;
        light.tanHalfFovY = 0.2;
        // light.tanHalfFovX = 0.4;
        // light.tanHalfFovY = 0.4;
        
        light.intensity = float3(10.0);
        light.nearZ = 0.01;
        light.farZ = 10000.0;

        // ProjectorLight light;
        // light.positionW = float3(0.1, 1.0, 6.8);
        // light.dirW = float3(0.0, 0.0, -1.0);
        // light.rightW = float3(1.0, 0.0, 0.0);
        // light.upW = float3(0.0, 1.0, 0.0);
        // light.tanHalfFovX = 0.2;
        // light.tanHalfFovY = 0.2;
        // light.intensity = float3(1.0);
        // light.nearZ = 0.01;
        // light.farZ = 10000.0;

        PeriodicPattern pattern;
        pattern.type = ProjectorPatternType(time_gate_mode);//ProjectorPatternType::kPatternSinusoidal;
        pattern.axis = gPatternUseVertical ? float2(1,0) : float2(0, 1);
        pattern.wavelength = time_gate_window;
        pattern.phase = 0.0;
        pattern.edge = 0.0;
        // return float3(time_gate_mode);

        // return float()

        // ArbitraryAntitheticPattern pattern;
        // pattern.width = 1024;
        // pattern.useVertical = gPatternUseVertical;
        // pattern.useOTMapping = (gPatternBaseBit > 0);

        // CheckerboardPattern pattern;
        // pattern.cellsU = 1024;
        // pattern.cellsV = 1024;
        // pattern.flip = (gPatternTotalBits == 0) ? 0 : (gPatternUseVertical ? 1 : 2);
        // pattern.shiftIndex = gPatternCurrentBit;

        // XORPattern pattern;
        // pattern.totalBits = gPatternTotalBits;
        // pattern.currentBit = gPatternCurrentBit;
        // pattern.useVertical = gPatternUseVertical;
        // pattern.baseBit = gPatternBaseBit;

        // GrayPattern pattern;
        // pattern.totalBits = gPatternTotalBits;
        // pattern.currentBit = gPatternCurrentBit;
        // pattern.useVertical = gPatternUseVertical;
        
        // pattern.axis = float2(1,0);
        // pattern.wavelength = time_gate_window;
        // pattern.phase = 0.0;

        light.pattern = pattern;

        for(uint i=0; i<samplesPerPixel; i++){
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);

            //
            // (1) First Hit Material
            //
            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            BSDFSample bsdfSample;

            HitInfo hit = hit0;
            float hitT;
            
            // no need for antithetic for first hit.
            if(kComputeDirect){
                if(hit.isValid() && any(throughput > 0.)){
                    float3 f = throughput * evalProjectedLightContribution(sd, light, mi, sg);
                    result += f;
                }
            }
#if USE_ANTITHETIC_SAMPLING
            ShadingData sd_prev = sd;
            IMaterialInstance mi_prev = mi;
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid(); depth++){
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                // throughput *= bsdfSample.weight;
                
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);

                if(hit.isValid() && any(throughput * bsdfSample.weight > 0.)){
                    // update sd, mi
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                    
                    // ------------------------------------------------------------
                    // primal + antithetic with MIS
                    // ------------------------------------------------------------
                    float3 f_primal      = float3(0.0f);
                    float3 f_antithetic = float3(0.0f);

                    bool primalValid = false;
                    bool antiDefined = false;

                    const float eps = 1e-6f;
                    
                    // ============================================================
                    // (1) Primal contribution data
                    // ============================================================
                    ProjectorSample ls = evalProjectorLight(light, sd.posW);

                    float3 L_primal = float3(0.0f);
                    float3 brdf_primal = float3(0.0f);
                    float p_bsdf_primal = bsdfSample.pdf;

                    if (ls.valid && p_bsdf_primal > eps)
                    {
                        bool V_light_primal = traceVisibilityRay(sd.computeRayOrigin(), ls.wi, ls.distance);

                        if (V_light_primal)
                        {
                            float G = 1.0f / (ls.distance * ls.distance);

                            L_primal = mi.eval(sd, ls.wi, sg) * ls.radiance * G;

                            // bsdfSample.weight = f / pdf
                            // so f = weight * pdf
                            brdf_primal = bsdfSample.weight * p_bsdf_primal;

                            primalValid = true;
                        }
                    }

                    // ============================================================
                    // (2) Antithetic mapping
                    // ============================================================
                    float3 L_anti = float3(0.0f);
                    float3 brdf_anti = float3(0.0f);

                    float p_bsdf_anti = 0.0f;
                    float p_map_anti  = 0.0f;
                    float p_map_primal = 0.0f;

                    // Jacobian convention:
                    // Jacobian = | d omega_anti / d omega_primal |
                    float Jacobian = 0.0f;

                    if (primalValid)
                    {
                        float2 uv_primal;

                        if (worldToProjectorUV(light, sd.posW, uv_primal))
                        {
                            float2 uv_anti = light.pattern.antitheticCoord(uv_primal, sampleNext1D(sg));
                            
                            if (all(uv_anti >= 0.0) && all(uv_anti <= 1.0))
                            {
                                float3 antiProjDirW;

                                if (projectorUVToWorldRay(light, uv_anti, antiProjDirW))
                                {
                                    float antiHitT;
                                    HitInfo hit_anti = traceRay(light.positionW, antiProjDirW, antiHitT);

                                    if (hit_anti.isValid())
                                    {
                                        ShadingData sd_anti = loadShadingData(hit_anti, light.positionW, antiProjDirW);

                                        IMaterialInstance mi_anti =
                                            gScene.materials.getMaterialInstance(
                                                sd_anti,
                                                ExplicitLodTextureSampler(0.f)
                                            );

                                        // ------------------------------------------------
                                        // Geometry for Jacobian
                                        // ------------------------------------------------
                                        float3 x  = sd_prev.posW;
                                        float3 y  = sd.posW;
                                        float3 ya = sd_anti.posW;
                                        float3 o  = light.positionW;

                                        float3 ny  = sd.getOrientedFaceNormal();       // preferably geometric normal
                                        float3 nya = sd_anti.getOrientedFaceNormal();  // preferably geometric normal

                                        float3 omega_primal = normalize(y  - x);
                                        float3 omega_anti   = normalize(ya - x);

                                        float3 d_primal = normalize(y  - o);
                                        float3 d_anti   = normalize(ya - o);

                                        float dist_x_y2  = dot(y  - x, y  - x);
                                        float dist_x_ya2 = dot(ya - x, ya - x);
                                        float dist_o_y2  = dot(y  - o, y  - o);
                                        float dist_o_ya2 = dot(ya - o, ya - o);

                                        float cos_y_w  = abs(dot(ny,  -omega_primal));
                                        float cos_ya_w = abs(dot(nya, -omega_anti));
                                        float cos_y_d  = abs(dot(ny,  -d_primal));
                                        float cos_ya_d = abs(dot(nya, -d_anti));

                                        float cos_oy  = abs(dot(light.dirW, d_primal));
                                        float cos_oya = abs(dot(light.dirW, d_anti));

                                        antiDefined =
                                            (dist_x_y2  > eps) &&
                                            (dist_x_ya2 > eps) &&
                                            (dist_o_y2  > eps) &&
                                            (dist_o_ya2 > eps) &&
                                            (cos_y_w  > eps) &&
                                            (cos_ya_w > eps) &&
                                            (cos_y_d  > eps) &&
                                            (cos_ya_d > eps);

                                        if (antiDefined)
                                        {
                                            // d omega / d xi
                                            float J_d_omega_d_xi = (cos_y_w / dist_x_y2) * (dist_o_y2 / cos_y_d) * (cos_oy * cos_oy * cos_oy);

                                            // d omega_anti / d xi_anti
                                            float J_d_omega_anti_d_xi_anti = (cos_ya_w / dist_x_ya2) * (dist_o_ya2 / cos_ya_d) * (cos_oya * cos_oya * cos_oya);

                                            // d xi_anti / d xi
                                            float antitheticJacobian = abs(light.pattern.antitheticJacobian(uv_primal));

                                            // d omega_anti / d omega
                                            // = (d omega_anti / d xi_anti) / (d omega / d xi) * (d xi_anti / d xi)
                                            Jacobian = J_d_omega_anti_d_xi_anti / J_d_omega_d_xi * antitheticJacobian;

                                            if (Jacobian > eps)
                                            {
                                                // ------------------------------------------------
                                                // PDFs
                                                // ------------------------------------------------

                                                // Forward mapped pdf:
                                                // p_map(omega_anti) = p_bsdf(omega_primal) * J
                                                p_map_anti = p_bsdf_primal / Jacobian;

                                                // Ordinary BSDF pdf at antithetic direction.
                                                // Replace evalPdf with your actual Falcor PDF function.
                                                p_bsdf_anti = mi_prev.evalPdf(sd_prev, omega_anti);

                                                // Reverse mapped pdf at primal:
                                                // p_map(omega_primal) = p_bsdf(omega_anti) / J
                                                p_map_primal = p_bsdf_anti * Jacobian;

                                                // ------------------------------------------------
                                                // Visibility of sd_prev -> sd_anti
                                                // This affects contribution, not antiDefined.
                                                // ------------------------------------------------
                                                float dist_prev_to_anti = sqrt(dist_x_ya2);

                                                bool V_prev_anti = traceVisibilityRay(
                                                    sd_prev.computeRayOrigin(),
                                                    omega_anti,
                                                    dist_prev_to_anti
                                                );

                                                if (V_prev_anti)
                                                {
                                                    ProjectorSample ls_anti = evalProjectorLight(light, sd_anti.posW);

                                                    if (ls_anti.valid)
                                                    {
                                                        bool V_light_anti = traceVisibilityRay(
                                                            sd_anti.computeRayOrigin(),
                                                            ls_anti.wi,
                                                            ls_anti.distance
                                                        );

                                                        if (V_light_anti)
                                                        {
                                                            float G_anti = 1.0f / (ls_anti.distance * ls_anti.distance);

                                                            L_anti =
                                                                mi_anti.eval(sd_anti, ls_anti.wi, sg)
                                                                * ls_anti.radiance
                                                                * G_anti;

                                                            brdf_anti = mi_prev.eval(sd_prev, omega_anti, sg);
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ============================================================
                    // (3) MIS accumulation
                    // ============================================================

                    if (antiDefined && p_map_anti > eps && p_map_primal > eps)
                    {
                        // Balance heuristic.
                        float w_primal =
                            p_bsdf_primal / max(p_bsdf_primal + p_map_primal, eps);

                        float w_anti =
                            p_map_anti / max(p_map_anti + p_bsdf_anti, eps);

                        f_primal =
                            throughput
                            * w_primal
                            * brdf_primal
                            / max(p_bsdf_primal, eps)
                            * L_primal;

                        f_antithetic =
                            throughput
                            * w_anti
                            * brdf_anti
                            / max(p_map_anti, eps)
                            * L_anti;

                        result += f_primal + f_antithetic;
                    }
                    else
                    {
                        // Mapping failed, so only primal technique exists.
                        if (primalValid)
                        {
                            f_primal =
                                throughput
                                * brdf_primal
                                / max(p_bsdf_primal, eps)
                                * L_primal;

                            result += f_primal;
                        }
                    }
                    // final update throughput
                    throughput *= bsdfSample.weight;
                    sd_prev = sd;
                    mi_prev = mi;
                }
            }
#elif USE_STRATIFIED_SAMPLING
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid(); depth++){  
                
                float v = sampleNext1D(sg);
                uint N = gStratifiedSample;
                // return float3(100.0);

                for(uint j=0; j<N; j++){
                    // v = sampleNext1D(sg);
                // ------------------------------------------------------------
                // Sample one projector ray: o -> y
                // ------------------------------------------------------------
                float u = (float(j) + sampleNext1D(sg)) / float(N);
                float2 uv;
                if (gPatternUseVertical){
                    uv = float2(v, u);
                } else {
                    uv = float2(u, v);
                }

                float3 rayDirW;
                float pdfRay;
                sampleRayfromProjector(light, uv, rayDirW, pdfRay);
                
                float projectorHitT;
                HitInfo projectorHit = traceRay(light.positionW, rayDirW, projectorHitT);

                if(projectorHit.isValid())
                {
                    ShadingData sdY = loadShadingData(projectorHit, light.positionW, rayDirW);
                    IMaterialInstance miY = gScene.materials.getMaterialInstance(sdY, ExplicitLodTextureSampler(0.f));

                    // ------------------------------------------------------------
                    // Connect current camera vertex x to projector-hit vertex y
                    // ------------------------------------------------------------
                    float3 x = sd.posW;
                    float3 y = sdY.posW;

                    float3 xToY = y - x;
                    float dist2XY = dot(xToY, xToY);
                    float distXY = sqrt(dist2XY);

                    if(distXY > 0.f)
                    {
                        float3 wiX = normalize(xToY);   // x -> y
                        float3 wiY = -wiX;            // y -> x

                        bool visible = traceVisibilityRay(sd.computeRayOrigin(), wiX, distXY);
                        //  && (abs(dot(sdY.getOrientedFaceNormal(), sd.getOrientedFaceNormal())) < (1.0-1e-5))
                        visible &= (dot(wiX, sd.getOrientedFaceNormal())) > 1e-6;
                        visible &= (dot(wiY, sdY.getOrientedFaceNormal())) > 1e-6;
                        
                        if(visible)
                        {
                            // ------------------------------------------------------------
                            // Convert projector ray pdf to equivalent solid-angle pdf from x.
                            //
                            // pdfRay      : pdf of projector ray direction o -> y
                            // pdfAreaY    : pdf of sampling surface point y
                            // pdfOmegaX   : pdf of sampling direction x -> y
                            // ------------------------------------------------------------
                            float3 oToY = y - light.positionW;
                            float dist2OY = dot(oToY, oToY);

                            float3 woProjector = normalize(oToY);  // o -> y
                            float3 wiProjAtY = -woProjector;     // y -> o

                            float cosYProj = abs(dot(sdY.getOrientedFaceNormal(), wiProjAtY));
                            float cosYX    = abs(dot(sdY.getOrientedFaceNormal(), wiY));

                            if(cosYProj > 0.0 && cosYX > 0.0)
                            {
                                float pdfAreaY = pdfRay * cosYProj / dist2OY;
                                float pdfOmegaX = pdfAreaY * dist2XY / cosYX;

                                if(pdfOmegaX > 0.0)
                                {
                                    // ------------------------------------------------------------
                                    // Projector emitted radiance along o -> y.
                                    // ------------------------------------------------------------
                                    float cosP = dot(woProjector, light.dirW);

                                    if(cosP > 0.f)
                                    {
                                        float pattern = light.pattern.eval(uv);

                                        float projectorScale = 1.f / (cosP * cosP * cosP);

                                        float3 Le = light.intensity * pattern * projectorScale;

                                        // ------------------------------------------------------------
                                        // BSDF at x and y.
                                        // ------------------------------------------------------------

                                        // At x, incoming direction is from y.
                                        // Falcor mi.eval() usually returns f * cos.
                                        float3 fx = mi.eval(sd, wiX, sg);
                                        float pdfOmegaXBSDF = mi.evalPdf(sd, wiX);

                                        // At y, incoming direction is from projector.
                                        // miY.eval() usually returns f * cosYProj.
                                        float3 fyCos = miY.eval(sdY, wiY, sg);

                                        float3 fy = fyCos / cosYX * cosYProj;

                                        // Geometry term for connection y -> x.
                                        // Since fx already contains cos at x,
                                        // only cos at y is needed here.
                                        float Gxy = 1.0 / dist2OY;

                                        float3 L = fx * fy * Le * Gxy / pdfOmegaX;
                                        
                                        // float misWeight = pdfOmegaX / (pdfOmegaX + pdfOmegaXBSDF);
                                        // L *= misWeight;

                                        result += throughput * L / float(N);
                                    }
                                }
                            }
                        }
                    }
                }
                }

                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);
                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);
                
                if(hit.isValid()){
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
                } else {
                    break;
                }

                if(false)
                {
                    ProjectorSample ls = evalProjectorLight(light, sd.posW);

                    if(ls.valid){
                        bool V_light = traceVisibilityRay(
                            sd.computeRayOrigin(),
                            ls.wi,
                            ls.distance
                        );
                        if(V_light)
                        {
                            float G = 1.0f / (ls.distance * ls.distance);

                            float3 L =
                                mi.eval(sd, ls.wi, sg)
                                * ls.radiance
                                * G;
                            
                            float3 rayDirW;
                            float pdfRay;
                            sampleRayfromProjector(light, ls.uv, rayDirW, pdfRay);

                            float pdfAreaY = pdfRay * abs(dot(sd.getOrientedFaceNormal(), ls.wi)) / (ls.distance * ls.distance);
                            float pdfOmegaX = pdfAreaY * (hitT * hitT) / abs(dot(sd.getOrientedFaceNormal(), bsdfSample.wo));

                            float misWeight = (bsdfSample.pdf / (bsdfSample.pdf + pdfOmegaX));
                            
                            // bsdfSample.weight already contains f / pdf for
                            // the sampled segment from previous vertex to current vertex.
                            result += throughput * L * misWeight;
                        }
                    }
                }
            }
#else
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid(); depth++){
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;
                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);
                hit = traceRay(sd.computeRayOrigin(!is_transmission), bsdfSample.wo, hitT);

                if(hit.isValid() && any(throughput > 0.)){
                    // update sd, mi
                    sd = loadShadingData(hit, sd.computeRayOrigin(!is_transmission), bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    ProjectorSample ls = evalProjectorLight(light, sd.posW);

                    if(ls.valid){
                        bool V_light = traceVisibilityRay(
                            sd.computeRayOrigin(),
                            ls.wi,
                            ls.distance
                        );
                        if(V_light)
                        {
                            float G = 1.0f / (ls.distance * ls.distance);

                            float3 L =
                                mi.eval(sd, ls.wi, sg)
                                * ls.radiance
                                * G;

                            // bsdfSample.weight already contains f / pdf for
                            // the sampled segment from previous vertex to current vertex.
                            result += throughput * L;
                        }
                    }
                }
            }
            // result = float3(1.0, 1.0, 1.0);
#endif
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
    gOutputColor[pixel] = float4(color, 1.f);
}
