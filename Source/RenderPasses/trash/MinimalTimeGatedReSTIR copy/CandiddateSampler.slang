#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;

struct TimeGatedSample
{
    float pdf;
    float3 f;
    float3 p;
    float3 n;
    HitInfo hit;
    float path_length;
}

export interface ITimeGatedCandidateSampler
{
    bool   sample(const ShadingData sd1, const IMaterialInstance mi1, const ShadingData sd2, const IMaterialInstance mi2, inout SampleGenerator sg, out TimeGatedSample ts);
    float  evalPdf(const ShadingData sd1, const IMaterialInstance mi1, const ShadingData sd2, const IMaterialInstance mi2);
};

export struct TimeGatedBRDFSampler:ITimeGatedCandidateSampler
{
    bool sample(const ShadingData sd1, const IMaterialInstance mi1, const ShadingData sd2, const IMaterialInstance mi2, inout SampleGenerator sg, out TimeGatedSample ts)
    {
        BSDFSample bsdfSample;

        // BSDF Importance Sampling
        if(!mi1.sample(sd1, sg, bsdfSample, true));
            return false;
        
        // Trace Ray
        float hitT;
        Ray ray = Ray(sd1.computeRayOrigin(), bsdfSample.wo, 0.f, FLT_MAX);
        SceneRayQuery<0> sceneRayQuery;
        HitInfo hit = sceneRayQuery.traceRay(ray, hitT);
        
        if(!hit.isValid())
            return false;
        
        ShadingData sd = loadShadingData(hit, sd1.computeRayOrigin(), bsdfSample.wo);
        IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        
        float3 f1 = bsdfSample.weight;
        float3 to_sd2 = normalize(sd2.posW - sd.posW);
        float3 to_sd2_dist = length(sd2.posW - sd.posW);
        float G23 = to_sd2_dist * to_sd2_dist;
        float3 f = bsdfSample.weight * mi.eval(sd, to_sd2, sg) * mi2.eval(sd2, -to_sd2, sg) / G23;
        
        float n21 = max(dot(sd.getOrientedFaceNormal(), -bsdfSample.wo), 0.0);
        float G12 = hitT * hitT;
        float p_brdf = (G12 == 0.0) ? 0.0 : bsdfSample.pdf * n21 / G12;
        float3 f_full = f * p_brdf;

        ts.f = f_full;
        ts.pdf = p_brdf;
        ts.hit = hit;
        ts.pathlength = hitT + to_sd2_dist;
        ts.p = sd.posW;
        ts.n = sd.getOrientedFaceNormal();

        return f1 * f2 * f3;
    }

    float  evalPdf(const ShadingData sd1, const IMaterialInstance mi1, const ShadingData sd2, const IMaterialInstance mi2)
    {

    }
};

export struct 