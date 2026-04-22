import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import TransientShiftmapping;
import LoadShadingData;
import Scene.RaytracingInline;
#include "Utils/Math/MathConstants.slangh"



struct Reservoir
{
    float3 f;
    float wSum;
    float M;
    float W;

    HitInfo rcVertexHit;
    HitInfo rcNextVertexHit;
    float3 rcNextVertexWi;
    float3 rcNextVertexIrradiance;
    float rcNextVertexPathLength;
    float rcVertexPathLength;
    uint rcVertexBounce;

    uint initRandomSeed;

    [mutating]
    bool update(float3 newf, float weight, inout SampleGenerator sg){
        this.wSum += weight;
        this.M += 1;
        if(sampleNext1D(sg) * this.wSum < weight){
            this.f = newf;
            return true;
        }
        return false;
    }
    __init()
    {
        this.wSum = 0;
        this.M = 0;
        this.f = float3(0.0);
        this.W = 0.0;
        this.rcNextVertexWi = float3(1,0,0);
        this.rcNextVertexIrradiance = float3(0.0);
        this.rcNextVertexPathLength = 0.0;
        this.rcVertexBounce = 0;
    }
};

Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
{
	Reservoir s = Reservoir();
	s.update(r1.f, luminance(r1.f) * r1.W * r1.M / (r1.M + r2.M), sg);
    s.update(r2.f, luminance(r2.f) * r2.W * r2.M / (r1.M + r2.M), sg);
    s.M = r1.M + r2.M;
    float pHat = luminance(s.f);
    s.W = (pHat == 0 || s.M == 0) ? 0 : (1 / pHat) * (s.wSum);
    return s;
}


float3 getPHat3(
    const ShadingData sd1,
    const IMaterialInstance mi1,
    const ShadingData sd2,
    const ShadingData sd3,
    const float d01,
    const float d34,
    const float target_dist,
    const float3 irradiance,
    inout SampleGenerator sg
){
    let mi2 = gScene.materials.getMaterialInstance(sd2, ExplicitLodTextureSampler(0));
    let mi3 = gScene.materials.getMaterialInstance(sd3, ExplicitLodTextureSampler(0));

    const float3 p1 = sd1.posW;
    const float3 p2 = sd2.posW;
    const float3 p3 = sd3.posW;

    const float3 n2 = sd2.getOrientedFaceNormal();

    const float3 l12 = p2 - p1;
    const float3 l32 = p2 - p3;
    const float3 v12 = normalize(l12);
    const float3 v32 = normalize(l32);
    const float d12 = length(p2 - p1);
    const float d32 = length(p2 - p3);
    float3 f1 = mi1.eval(sd1, v12, sg);
    float3 f2 = mi2.eval(sd2, -v32, sg);
    float3 f3 = mi3.eval(sd3, v32, sg);
    float n21 = max(dot(n2, -v12), 0.0);
    if(n21 < 1e-6)
        return float3(0.0);

    float G12 = dot(l12, l12);
    float G23 = dot(l32, l32);
    if(G12 < 1e-9 || G23 < 1e-9)
        return float3(0.0);

    float3 f = f1 * f2 * f3 * n21 / (G12 * G23) * irradiance;
    float distance = d01 + d12 + d32 + d34;
    f *= pathLengthImportance(distance, target_dist);
    f = float3(f.x);
    f = float3(pathLengthImportance(distance, target_dist));
    return f;
}

bool checkVisibility(const float3 p1, const float3 p2)
{
    Ray visibilityRay = Ray(p1, normalize(p2 - p1), 0.001f, length(p1 - p2) - 0.001f);
    SceneRayQuery<0> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

Reservoir combine_reservoirs_with_shiftmapping(
    Reservoir prev_reservoir,
    Reservoir curr_reservoir,
    ShadingData prev_x1,
    ShadingData curr_x1,
    IMaterialInstance prev_x1_mi,
    IMaterialInstance curr_x1_mi,
    float prev_d01,
    float curr_d01,
    const float prev_t,
    const float curr_t,
    inout SampleGenerator sg
)
{
    ShadingData prev_x3 = loadShadingData(prev_reservoir.rcNextVertexHit, float3(0.0), prev_reservoir.rcNextVertexWi);
    ShadingData curr_x3 = loadShadingData(curr_reservoir.rcNextVertexHit, float3(0.0), curr_reservoir.rcNextVertexWi);
    float prev_d34 = prev_reservoir.rcNextVertexPathLength;
    float curr_d34 = curr_reservoir.rcNextVertexPathLength;
    float prev_rcPathLength = prev_reservoir.rcVertexPathLength;
    float curr_rcPathLength = curr_reservoir.rcVertexPathLength;
    
	Reservoir new_reservoir;
    
    float M_curr = curr_reservoir.M;//min(curr_reservoir.M, 640.0);
	float M_prev = prev_reservoir.M;//min(prev_reservoir.M, 640.0);

    VertexData v_curr  = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
    VertexData v_prev  = gScene.getVertexData(prev_reservoir.rcVertexHit.getTriangleHit());
    
    float dt_target = curr_t - prev_t;


    // (1) curr
    // (1-1) curr as curr
    float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);
    
    // (1-2) curr as prev
    float jacobian = 0.0;
    ShiftMapDebugInfo debugInfo;
    
    float3 prev_prefix_throughput = float3(1.0);
    if(curr_reservoir.rcVertexBounce > 1){
        HitInfo hit;
        float hitT;
        BSDFSample bsdfSample;
        SampleGenerator sg_new = SampleGenerator(curr_reservoir.initRandomSeed);

        for(uint depth=1; depth < curr_reservoir.rcVertexBounce; depth++){
            prev_x1_mi.sample(prev_x1, sg_new, bsdfSample, true);
            // skip
            sampleNext2D(sg); // for light sampling
            sampleNext1D(sg); // for reservoir update

            prev_prefix_throughput *= bsdfSample.weight;
            Ray ray = Ray(prev_x1.computeRayOrigin(), bsdfSample.wo, 1e-4f, FLT_MAX);
            SceneRayQuery<0> sceneRayQuery;
            hit = sceneRayQuery.traceRay(ray, hitT);
            if(!hit.isValid()){
                prev_prefix_throughput = 0.0;
                break;
            }
            prev_d01 += hitT;
            prev_x1 = loadShadingData(hit, ray.origin, ray.dir);
            prev_x1_mi = gScene.materials.getMaterialInstance(prev_x1, ExplicitLodTextureSampler(0.f));
        }
    }
    
    
    float l_curr = curr_rcPathLength + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float l_curr_as_prev = prev_d01 + length(prev_x1.posW - v_curr.posW) + length(v_curr.posW - curr_x3.posW) + curr_d34;
    float dt_curr = (l_curr - dt_target) - l_curr_as_prev;
    float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);

    HitInfo y_curr_as_prev = transient_shift_mapping(
        prev_x1, curr_reservoir.rcVertexHit, curr_x3, dt_curr, jacobian, debugInfo, tol_curr, sg);

    VertexData v_curr_as_prev = gScene.getVertexData(y_curr_as_prev.getTriangleHit());
    
    ShadingData y_curr_as_prev_sd = loadShadingData(
        y_curr_as_prev, prev_x1.posW,
        normalize(v_curr_as_prev.posW - prev_x1.posW));

    float3 f_curr_as_prev = prev_prefix_throughput * getPHat3(prev_x1, prev_x1_mi, y_curr_as_prev_sd, curr_x3, prev_d01, curr_d34, prev_t, 
        curr_reservoir.rcNextVertexIrradiance, sg);
    f_curr_as_prev *= checkVisibility(prev_x1.posW, y_curr_as_prev_sd.posW);
    if(curr_reservoir.W == 0.0){
        f_curr_as_prev = 0.0;
    }
    if(curr_reservoir.rcVertexBounce == 0){
        f_curr_as_prev = 0.0;
    }

    float pHat_proxy_curr_as_prev = (jacobian == 0.0) ? 0.0 : luminance(f_curr_as_prev);

    float nom = M_curr * pHat_proxy_curr_as_curr;
	float denom = nom + M_prev * pHat_proxy_curr_as_prev * jacobian;
	float m_curr = (denom == 0.0) ? 0.0 : nom / denom;
    
    float weight_curr = m_curr * pHat_proxy_curr_as_curr * curr_reservoir.W;

    if(new_reservoir.update(curr_reservoir.f, weight_curr, sg)){
        new_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
        new_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
        new_reservoir.rcNextVertexWi = curr_reservoir.rcNextVertexWi;
        new_reservoir.rcNextVertexIrradiance = curr_reservoir.rcNextVertexIrradiance;
        new_reservoir.rcNextVertexPathLength = curr_reservoir.rcNextVertexPathLength;
        new_reservoir.rcVertexPathLength = curr_reservoir.rcVertexPathLength;
        new_reservoir.rcVertexBounce = curr_reservoir.rcVertexBounce;
    }

    // (2) prev
    float pHat_proxy_prev_as_prev = luminance(prev_reservoir.f);

    float3 curr_prefix_throughput = float3(1.0);
    if(prev_reservoir.rcVertexBounce > 1){
        HitInfo hit;
        float hitT;
        BSDFSample bsdfSample;
        SampleGenerator sg_new = SampleGenerator(prev_reservoir.initRandomSeed);

        for(uint depth=1; depth < prev_reservoir.rcVertexBounce; depth++){
            curr_x1_mi.sample(curr_x1, sg_new, bsdfSample, true);
            // skip
            sampleNext2D(sg); // for light sampling
            sampleNext1D(sg); // for reservoir update

            curr_prefix_throughput *= bsdfSample.weight;
            Ray ray = Ray(curr_x1.computeRayOrigin(), bsdfSample.wo, 1e-4f, FLT_MAX);
            SceneRayQuery<0> sceneRayQuery;
            hit = sceneRayQuery.traceRay(ray, hitT);
            if(!hit.isValid()){
                curr_prefix_throughput = 0.0;
                break;
            }
            curr_d01 += hitT;
            curr_x1 = loadShadingData(hit, ray.origin, ray.dir);
            curr_x1_mi = gScene.materials.getMaterialInstance(curr_x1, ExplicitLodTextureSampler(0.f));
        }
    }

    float l_prev = prev_rcPathLength + length(v_prev.posW - prev_x3.posW) + prev_d34;
    float l_prev_as_curr = curr_d01 + length(curr_x1.posW - v_prev.posW) + length(v_prev.posW - prev_x3.posW) + prev_d34;
    float dt_prev = (l_prev + dt_target) - l_prev_as_curr;
    float tol_prev = max(abs(dt_prev) * 0.01, 1e-6);

    float jacobian2 = 0.0;
    HitInfo y_prev_as_curr = transient_shift_mapping(
         curr_x1, prev_reservoir.rcVertexHit, prev_x3, dt_prev, jacobian2, debugInfo, tol_prev, sg);

    
    VertexData v_prev_as_curr = gScene.getVertexData(y_prev_as_curr.getTriangleHit());
    ShadingData y_prev_as_curr_sd = loadShadingData(
        y_prev_as_curr, curr_x1.posW, normalize(v_prev_as_curr.posW - curr_x1.posW));


    float l_prev_as_curr2 = curr_d01 + length(curr_x1.posW - y_prev_as_curr_sd.posW) 
        + length(y_prev_as_curr_sd.posW - prev_x3.posW) + prev_d34;
    float dt_prev2 = (l_prev + dt_target) - l_prev_as_curr2;

    float3 f_prev_as_curr = curr_prefix_throughput * getPHat3(curr_x1, curr_x1_mi, y_prev_as_curr_sd,
        prev_x3, curr_d01, prev_d34, curr_t, 
        prev_reservoir.rcNextVertexIrradiance, sg);

    f_prev_as_curr *= checkVisibility(curr_x1.posW, y_prev_as_curr_sd.posW);
    if(prev_reservoir.W == 0.0){
        f_prev_as_curr = 0.0;
    }
    if(prev_reservoir.rcVertexBounce == 0){
        f_prev_as_curr = 0.0;
    }

    float m_prev = 0.0;
	float pHat_proxy_prev_as_curr = 0.0;
	if(jacobian2 > 0.0){
		pHat_proxy_prev_as_curr = luminance(f_prev_as_curr);
		float nom = M_prev * pHat_proxy_prev_as_prev / jacobian2;
		float denom = nom + M_curr * pHat_proxy_prev_as_curr;
		m_prev = (denom == 0.0) ? 0.0 : nom / denom;
	}
    float weight_prev = m_prev * pHat_proxy_prev_as_curr * prev_reservoir.W * jacobian2;
	if(new_reservoir.update(f_prev_as_curr, weight_prev, sg)){
        new_reservoir.rcVertexHit = y_prev_as_curr;
        new_reservoir.rcNextVertexHit = prev_reservoir.rcNextVertexHit;
        new_reservoir.rcNextVertexWi = prev_reservoir.rcNextVertexWi;
        new_reservoir.rcNextVertexIrradiance = prev_reservoir.rcNextVertexIrradiance;
        new_reservoir.rcNextVertexPathLength = prev_reservoir.rcNextVertexPathLength;
        new_reservoir.rcVertexPathLength = curr_d01 + length(curr_x1.posW - v_prev.posW);
        new_reservoir.rcVertexBounce = prev_reservoir.rcVertexBounce;
    }

    float pHat_new = luminance(new_reservoir.f);
    new_reservoir.W = (pHat_new == 0) ? 0 : (1.0f / pHat_new) * new_reservoir.wSum;
    new_reservoir.M = M_curr + M_prev;
    // new_reservoir.f = prev_reservoir.rcVertexBounce > 1 ? float3(pathLengthImportance(l_prev, tcurr)) : float3(0.0);

    return new_reservoir;
}