import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import TransientShiftmapping;
import LoadShadingData;


cbuffer Laser_CB
{
    float3 laserOrigin;
    float3 laserDirection;
    float3 laserPower;
}


struct Reservoir
{
    float3 f;
    float wSum;
    float M;
    float W;

    LightSample lightSample;
    LightSample lightSample2;
    float3 direction;
    float3 radiance;
    float postfixPathLength;

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
    const ShadingData sd2,
    const ShadingData sd3,
    const float d01,
    const float d34,
    const float target_dist,
    inout SampleGenerator sg
){
    let mi1 = gScene.materials.getMaterialInstance(sd1, ExplicitLodTextureSampler(0));
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
    float3 f2 = mi2.eval(sd2, -v12, sg);
    float3 f3 = mi3.eval(sd3, v32, sg);
    float n23 = max(dot(n2, -v32), 0.0);
    float G12 = dot(l12, l12);
    float G23 = dot(l32, l32);

    float3 f = f1 * f2 * f3 * n23 / (G12 * G23) * laserPower;
    float distance = d01 + d12 + d32 + d34;
    f *= pathLengthImportance(distance, target_dist);
    f = float3(f.x);
    return f;
}

Reservoir combine_reservoirs_with_shiftmapping(
    Reservoir prev_reservoir,
    Reservoir curr_reservoir,
    // ShadingData curr_reservoir_sd,
    // ShadingData prev_reservoir_sd,
    ShadingData prev_x1,
    ShadingData curr_x1,
    float prev_d01,
    float curr_d01,
    float dt_target,
    inout SampleGenerator sg
)
{
    ShadingData prev_x3 = loadShadingData(prev_reservoir.lightSample2.hit, prev_reservoir.lightSample2.p -prev_reservoir.direction, -prev_reservoir.direction);
    ShadingData curr_x3 = loadShadingData(curr_reservoir.lightSample2.hit, curr_reservoir.lightSample2.p -curr_reservoir.direction, -curr_reservoir.direction);
    float prev_d34 = prev_reservoir.postfixPathLength;
    float curr_d34 = curr_reservoir.postfixPathLength;
    

	Reservoir new_reservoir;
	new_reservoir.wSum = 0;
	new_reservoir.W = 0;
	new_reservoir.M = 0;

    float M_curr = curr_reservoir.M;//min(curr_reservoir.M, 640.0);
	float M_prev = prev_reservoir.M;//min(prev_reservoir.M, 640.0);

    LightSample y_curr = curr_reservoir.lightSample;
    LightSample y_prev = prev_reservoir.lightSample;
    
    float l_prev = prev_d01 + length(prev_x1.posW - y_prev.p) + length(y_prev.p - prev_x3.posW) + prev_d34;
    float l_curr = curr_d01 + length(curr_x1.posW - y_curr.p) + length(y_curr.p - curr_x3.posW) + curr_d34;
    float l_prev_as_curr = curr_d01 + length(curr_x1.posW - y_prev.p) + length(y_prev.p - curr_x3.posW) + curr_d34;
    float l_curr_as_prev = prev_d01 + length(prev_x1.posW - y_curr.p) + length(y_curr.p - prev_x3.posW) + prev_d34;

    float dt_prev = (l_prev + dt_target) - l_prev_as_curr;
    float dt_curr = (l_curr - dt_target) - l_curr_as_prev;
    // float dt = l_prev + dt_target - l_prev_as_curr;
    // (tcurr - tprev);

    float tol_prev = max(abs(dt_prev) * 0.01, 1e-6);
    float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);

    // (1) curr
    // (1-1) curr as curr
    float pHat_proxy_curr_as_curr = luminance(curr_reservoir.f);
    
    // (1-2) curr as prev
    float jacobian = 0.0;
    ShiftMapDebugInfo debugInfo;

    LightSample light_sample_curr_as_prev = transient_shift_mapping(prev_x1, y_curr, prev_x3, dt_curr, jacobian, debugInfo, tol_curr);
    ShadingData light_sample_curr_as_prev_sd = loadShadingData(light_sample_curr_as_prev.hit, prev_x3.posW, normalize(light_sample_curr_as_prev.p - prev_x3.posW));

    float3 f_curr_as_prev = getPHat3(prev_x1, light_sample_curr_as_prev_sd, prev_x3, prev_d01, prev_d34, tcurr, sg);
    float pHat_proxy_curr_as_prev = (jacobian == 0.0) ? 0.0 : luminance(f_curr_as_prev);

    float nom = M_curr * pHat_proxy_curr_as_curr;
	float denom = nom + M_prev * pHat_proxy_curr_as_prev * jacobian;
	float m_curr = (denom == 0.0) ? 0.0 : nom / denom;
    
    float weight_curr = m_curr * pHat_proxy_curr_as_curr * curr_reservoir.W;

    if(new_reservoir.update(curr_reservoir.f, weight_curr, sg)){
        reservoir.lightSample = curr_reservoir.lightSample;
        reservoir.lightSample2 = curr_reservoir.lightSample2;
        reservoir.direction = curr_reservoir.direction;
        reservoir.radiance = curr_reservoir.radiance;
        reservoir.postfixPathLength = curr_reservoir.postfixPathLength;
    }


    // (2) prev
    float pHat_proxy_prev_as_prev = luminance(prev_reservoir.f);

    float jacobian2 = 0.0;
    LightSample light_sample_prev_as_curr = transient_shift_mapping(curr_x1, y_prev, curr_x3, dt_prev, jacobian2, debugInfo, tol_prev);
    ShadingData light_sample_prev_as_curr_sd = loadShadingData(light_sample_prev_as_curr.hit, curr_x3.posW, normalize(light_sample_prev_as_curr.p - curr_x3.posW));

    float3 f_prev_as_curr = getPHat3(curr_x1, light_sample_prev_as_curr_sd, curr_x3, curr_d01, curr_d34, tcurr, sg);
    float m_prev = 0.0;
	float pHat_proxy_prev_as_curr = 0.0;
	if(jacobian2 > 0.0){
		pHat_proxy_prev_as_curr = luminance(f_prev_as_curr);
		float nom = M_prev * pHat_proxy_prev_as_prev / jacobian2;
		float denom = nom + M_curr * pHat_proxy_prev_as_curr;
		m_prev = (denom == 0.0) ? 0.0 : nom / denom;
	}
    float weight_prev = m_prev * pHat_proxy_prev_as_curr * prev_reservoir.W * jacobian2;
	bool is_prev_selected = new_reservoir.update(f_prev_as_curr, weight_prev, sg);

    float pHat_new = luminance(new_reservoir.f);
    new_reservoir.W = (pHat_new == 0) ? 0 : (1.0f / pHat_new) * new_reservoir.wSum;
    new_reservoir.M = M_curr + M_prev;

    // new_reservoir.dummy = float(pHat_proxy_prev_as_curr > 0.0 ? 1.0 : 0.0);
    // float L_total_0 = length(x1.posW - prev_reservoir.lightSample.p) + length(x3.posW - prev_reservoir.lightSample.p);
    // float L_total_1 = length(x1.posW - light_sample_prev_as_curr.p) + length(x3.posW - light_sample_prev_as_curr.p);
    // new_reservoir.dummy = float3(prev_reservoir.W, float(checkVisibility(x1.computeRayOrigin(), prev_reservoir.lightSample.p)), 0.0);//(jacobian2 > 0.0) ? dummyinfo : float3(0.1);
    // new_reservoir.dummy = (jacobian2 > 0.0) ? dummyinfo : 0.0;
    // new_reservoir.dummy = float3(y_prev.uv.x, y_prev.uv.y, 0.0);//debugInfo.temp;//
    // new_reservoir.dummy =  (jacobian2 > 0.0) ? float3(abs(L_total_1 - L_total_0)) : float3(0.0);
    // new_reservoir.dummy =  (jacobian2 > 0.0) ? float3(1.0) : float3(0.0);

    // if(prev_reservoir.W == 0){
    //     new_reservoir.dummy = float3(0.0);
    // }
	// new_reservoir.lightSample.valid = (pHat_new > 0);
    return new_reservoir;
}