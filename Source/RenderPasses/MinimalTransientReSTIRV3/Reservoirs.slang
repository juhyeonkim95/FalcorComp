import Utils.Color.ColorHelpers;
import Utils.Transient.TransientUtils;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;
import TransientShiftmapping;
import LoadShadingData;
import Scene.RaytracingInline;
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import LaserLightSampler;
import Rendering.Lights.LightHelpers;


static const bool kUseSingleChannel = false;


float getReservoirWeight(float3 f){
#if USE_SINGLE_CHANNEL
    return f.x;
#else
    return luminance(f);
#endif
}

float getReservoirWeight(float f){
    return f;
}


struct Reservoir
{
#if USE_SINGLE_CHANNEL
    float f;
#else
    float3 f;
#endif
    float wSum;
    float M;
    float W;

    HitInfo rcVertexHit;
    HitInfo rcNextVertexHit;
    float totalPathLength;

    [mutating]
    bool update(float3 newf, float weight, float M, inout SampleGenerator sg){
        this.wSum += weight;
        this.M += M;
        if(sampleNext1D(sg) * this.wSum < weight){
            #if USE_SINGLE_CHANNEL
            this.f = getReservoirWeight(newf);
            #else
            this.f = newf;
            #endif
            return true;
        }
        return false;
    }
    __init()
    {
        this.wSum = 0;
        this.M = 0;
        this.f = 0.0;
        this.W = 0.0;
    }
};

Reservoir combine_reservoirs(Reservoir r1, Reservoir r2, inout SampleGenerator sg)
{
	Reservoir s = Reservoir();
	s.update(r1.f, getReservoirWeight(r1.f) * r1.W * r1.M / (r1.M + r2.M), r1.M, sg);
    s.update(r2.f, getReservoirWeight(r2.f) * r2.W * r2.M / (r1.M + r2.M), r2.M, sg);
    // s.M = r1.M + r2.M;
    float pHat = getReservoirWeight(s.f);
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

    const float3 p1 = sd1.posW;
    const float3 p2 = sd2.posW;
    const float3 p3 = sd3.posW;

    const float3 n2 = sd2.getOrientedFaceNormal();

    const float3 l12 = p2 - p1;
    const float3 l32 = p2 - p3;
    const float3 v12 = normalize(l12);
    const float3 v32 = normalize(l32);

    float3 f1 = mi1.eval(sd1, v12, sg);
    float3 f2 = mi2.eval(sd2, -v32, sg);
    float3 f3 = dot(sd3.getOrientedFaceNormal(), v32) > 0.0 ? float3(1.0) : float3(0.0);

    float n21 = max(dot(n2, -v12), 0.0);
    if(n21 < 1e-6)
        return float3(0.0);

    float G12 = max(dot(l12, l12), kMinLightDistSqr);
    float G23 = max(dot(l32, l32), kMinLightDistSqr);

    float3 f = f1 * f2 * f3 * n21 / (G12 * G23) * irradiance;
    if (any(isinf(f) || isnan(f))) f = 0.f;
    float distance = d01 + length(p2 - p1) + length(p3 - p2) + d34;
    f *= pathLengthImportance(distance, target_dist);

    return f;
}

float3 getPHat3v2(
    const ShadingData sd1,
    const IMaterialInstance mi1,
    const ShadingData sd2,
    const ShadingData sd3,
    const ShadingData sd4,
    const float d01,
    const float d45,
    const float target_dist,
    const float3 irradiance,
    inout SampleGenerator sg
){
    let mi2 = gScene.materials.getMaterialInstance(sd2, ExplicitLodTextureSampler(0));
    let mi3 = gScene.materials.getMaterialInstance(sd3, ExplicitLodTextureSampler(0));

    const float3 p1 = sd1.posW;
    const float3 p2 = sd2.posW;
    const float3 p3 = sd3.posW;
    const float3 p4 = sd4.posW;

    const float3 n2 = sd2.getOrientedFaceNormal();
    const float3 n3 = sd3.getOrientedFaceNormal();

    const float3 l12 = p2 - p1;
    const float3 l23 = p3 - p2;
    const float3 l34 = p4 - p3;
    const float3 v12 = normalize(l12);
    const float3 v23 = normalize(l23);
    const float3 v34 = normalize(l34);

    float3 f1 = mi1.eval(sd1, v12, sg);
    float3 f2 = mi2.eval(sd2, v23, sg);
    float3 f3 = mi3.eval(sd3, v34, sg);

    float3 f4 = dot(sd4.getOrientedFaceNormal(), -v34) > 0.0 ? float3(1.0) : float3(0.0);

    float n21 = max(dot(n2, -v12), 0.0);
    if(n21 < 1e-6)
        return float3(0.0);
    float n32 = max(dot(n3, -v23), 0.0);
    if(n32 < 1e-6)
        return float3(0.0);

    float G12 = max(dot(l12, l12), kMinLightDistSqr);
    float G23 = max(dot(l23, l23), kMinLightDistSqr);
    float G34 = max(dot(l34, l34), kMinLightDistSqr);

    float3 f = f1 * f2 * f3 * f4 * n21 * n32 / (G12 * G23 * G34) * irradiance;

    if (any(isinf(f) || isnan(f))) f = 0.f;
    float distance = d01 + length(p2 - p1) + length(p3 - p2) + length(p4 - p3) + d45;
    f *= pathLengthImportance(distance, target_dist);
    return f;
}

bool checkVisibility(const float3 p1, const float3 p2)
{
    Ray visibilityRay = Ray(p1, normalize(p2 - p1), 0.000f, length(p1 - p2) - 0.001f);
    SceneRayQuery<0> sceneRayQuery;
    return sceneRayQuery.traceVisibilityRay(visibilityRay);
}

// this shifts curr to other.
void combine_reservoir_with_shiftmapping(
    inout Reservoir dst_reservoir,
    Reservoir curr_reservoir,
    float M_other,
    ShadingData other_x1,
    IMaterialInstance other_x1_mi,
    float other_d01,
    const float other_t,
    const float curr_t,
    bool is_curr_canonical,
    float3 laserPosition,   // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    float3 laserDirection,  // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    float3 laserPower,  // this is to handle invalid curr_reservoir.rcNextVertex (point light)
    inout SampleGenerator sg
){
    // no valid sample in reservoir
    if(curr_reservoir.W == 0.0)
    {
        dst_reservoir.M += curr_reservoir.M;
        return;
    }
    
    ShiftMapDebugInfo debugInfo;
    // 1 - bounce
    if(!curr_reservoir.rcNextVertexHit.isValid()){
        ShadingData curr_x3;

        curr_x3.posW = laserPosition;
        curr_x3.frontFacing = true;
        curr_x3.faceN = laserDirection;
        
        VertexData v_curr = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());

        float l_curr = curr_reservoir.totalPathLength;
        float l_curr_as_other = other_d01 + length(other_x1.posW - v_curr.posW) + length(v_curr.posW - curr_x3.posW);

        float l_target = (l_curr - curr_t) + other_t;
        float dt_curr = l_target - l_curr_as_other;

        float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);
    
        // evaluate path-length aware shift mapping
        float jacobian = 0.0;

        HitInfo curr_hit2_new = transient_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3,
            dt_curr, jacobian, debugInfo, tol_curr, sg);
        
        // load information at new point
        VertexData curr_v2_new = gScene.getVertexData(curr_hit2_new.getTriangleHit());
        ShadingData curr_x2_new = loadShadingData(
                curr_hit2_new, other_x1.posW,
                normalize(curr_v2_new.posW - other_x1.posW));

        float3 f_curr_as_other = getPHat3(
                other_x1, other_x1_mi,
                curr_x2_new, 
                curr_x3,
                other_d01, 0.0, other_t, 
                laserPower, sg);

        f_curr_as_other *= checkVisibility(other_x1.computeRayOrigin(), curr_x2_new.posW);

        if(jacobian == 0.0){
            f_curr_as_other = 0.0;
        }
        float pHat_proxcurr_hit2_new = getReservoirWeight(f_curr_as_other);
        float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
        float M_curr = curr_reservoir.M;
    
        float nom = M_curr * pHat_proxy_curr_as_curr;
        float denom = nom + M_other * pHat_proxcurr_hit2_new * jacobian;
        float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

        if(is_curr_canonical){
            float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
            if(dst_reservoir.update(curr_reservoir.f, weight, M_curr, sg)){
                dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
                dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
                dst_reservoir.totalPathLength = curr_reservoir.totalPathLength;
            }
        } else {
            float weight = mis_weight * pHat_proxcurr_hit2_new * curr_reservoir.W * jacobian;
            if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
                dst_reservoir.rcVertexHit = curr_hit2_new;
                dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
                float pathLengthNew = other_d01 + length(other_x1.posW - curr_v2_new.posW) + length(curr_v2_new.posW - curr_x3.posW);
                dst_reservoir.totalPathLength = pathLengthNew;
            }
        }
    } 
    // 2 - bounce
    else {

        ShadingData curr_x4;

        curr_x4.posW = laserPosition;
        curr_x4.frontFacing = true;
        curr_x4.faceN = laserDirection;

        VertexData curr_v2 = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
        VertexData curr_v3 = gScene.getVertexData(curr_reservoir.rcNextVertexHit.getTriangleHit());
        
        ShadingData curr_x3 = loadShadingData(
            curr_reservoir.rcNextVertexHit, curr_v2.posW,
            normalize(curr_v3.posW - curr_v2.posW));


        float l_curr = curr_reservoir.totalPathLength;
        float l_curr_as_other = other_d01 + length(other_x1.posW - curr_v2.posW) + length(curr_v2.posW - curr_v3.posW) + length(curr_v3.posW - curr_x4.posW);

        float l_target = (l_curr - curr_t) + other_t;
        float dt_curr = l_target - l_curr_as_other;

        float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);
    
        // evaluate path-length aware shift mapping
        float jacobian = 0.0;
        
        HitInfo curr_hit2_new = transient_shift_mapping(
            other_x1, curr_reservoir.rcVertexHit, curr_x3,
                dt_curr, jacobian,
                debugInfo, tol_curr, sg);

        // load information at new point
        VertexData curr_v2_new = gScene.getVertexData(curr_hit2_new.getTriangleHit());
        ShadingData curr_x2_new = loadShadingData(
            curr_hit2_new, other_x1.posW,
                normalize(curr_v2_new.posW - other_x1.posW));

        float3 f_curr_as_other = getPHat3v2(
                other_x1, other_x1_mi,
                curr_x2_new,
                curr_x3, 
                curr_x4,
                other_d01, 0.0, other_t, 
                laserPower, sg);

        f_curr_as_other *= checkVisibility(other_x1.computeRayOrigin(), curr_x2_new.posW);
        

        if(jacobian == 0.0){
            f_curr_as_other = 0.0;
        }
        float pHat_proxcurr_hit2_new = getReservoirWeight(f_curr_as_other);
        float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
        float M_curr = curr_reservoir.M;
    
        float nom = M_curr * pHat_proxy_curr_as_curr;
        float denom = nom + M_other * pHat_proxcurr_hit2_new * jacobian;
        float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

        if(is_curr_canonical){
            float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
            if(dst_reservoir.update(curr_reservoir.f, weight, M_curr, sg)){
                dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
                dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
                dst_reservoir.totalPathLength = curr_reservoir.totalPathLength;
            }
        } else {
            float weight = mis_weight * pHat_proxcurr_hit2_new * curr_reservoir.W * jacobian;
            if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
                dst_reservoir.rcVertexHit = curr_hit2_new;
                dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
                float pathLengthNew = other_d01 + length(other_x1.posW - curr_v2_new.posW) + length(curr_v2_new.posW - curr_v3.posW) 
                    + length(curr_v3.posW - curr_x4.posW);
                dst_reservoir.totalPathLength = pathLengthNew;
            }
        }



        // ShadingData curr_x4;

        // curr_x4.posW = laserPosition;
        // curr_x4.frontFacing = true;
        // curr_x4.faceN = laserDirection;

        // VertexData curr_v2 = gScene.getVertexData(curr_reservoir.rcVertexHit.getTriangleHit());
        // VertexData curr_v3 = gScene.getVertexData(curr_reservoir.rcNextVertexHit.getTriangleHit());

        // ShadingData curr_x2 = loadShadingData(
        //     curr_reservoir.rcVertexHit, other_x1.posW,
        //     normalize(curr_v2.posW - other_x1.posW));
        
        // float l_curr = curr_reservoir.totalPathLength;
        // float l_curr_as_other = other_d01 + length(other_x1.posW - curr_v2.posW) + length(curr_v2.posW - curr_v3.posW) + length(curr_v3.posW - curr_x4.posW);

        // float l_target = (l_curr - curr_t) + other_t;
        // float dt_curr = l_target - l_curr_as_other;

        // float tol_curr = max(abs(dt_curr) * 0.01, 1e-6);
    
        // // evaluate path-length aware shift mapping
        // float jacobian = 0.0;
        
        // HitInfo curr_hit3_new = transient_shift_mapping(
        //     curr_x2, curr_reservoir.rcNextVertexHit, curr_x4,
        //         dt_curr, jacobian,
        //         debugInfo, tol_curr, sg);

        // // load information at new point
        // VertexData curr_v3_new = gScene.getVertexData(curr_hit3_new.getTriangleHit());
        // ShadingData curr_x3_new = loadShadingData(
        //         curr_hit3_new, curr_x2.posW,
        //         normalize(curr_v3_new.posW - curr_x2.posW));

        // float3 f_curr_as_other = getPHat3v2(
        //         other_x1, other_x1_mi,
        //         curr_x2,
        //         curr_x3_new, 
        //         curr_x4,
        //         other_d01, 0.0, other_t, 
        //         laserPower, sg);

        // f_curr_as_other *= checkVisibility(curr_x2.computeRayOrigin(), curr_x3_new.posW);

        // if(jacobian == 0.0){
        //     f_curr_as_other = 0.0;
        // }
        // float pHat_proxcurr_hit2_new = getReservoirWeight(f_curr_as_other);
        // float pHat_proxy_curr_as_curr = getReservoirWeight(curr_reservoir.f);
        // float M_curr = curr_reservoir.M;
    
        // float nom = M_curr * pHat_proxy_curr_as_curr;
        // float denom = nom + M_other * pHat_proxcurr_hit2_new * jacobian;
        // float mis_weight = (denom == 0.0) ? 0.0 : nom / denom;

        // if(is_curr_canonical){
        //     float weight = mis_weight * pHat_proxy_curr_as_curr * curr_reservoir.W;
        //     if(dst_reservoir.update(curr_reservoir.f, weight, M_curr, sg)){
        //         dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;
        //         dst_reservoir.rcNextVertexHit = curr_reservoir.rcNextVertexHit;
        //         dst_reservoir.totalPathLength = curr_reservoir.totalPathLength;
        //     }
        // } else {
        //     float weight = mis_weight * pHat_proxcurr_hit2_new * curr_reservoir.W * jacobian;
        //     if(dst_reservoir.update(f_curr_as_other, weight, M_curr, sg)){
        //         dst_reservoir.rcVertexHit = curr_reservoir.rcVertexHit;;
        //         dst_reservoir.rcNextVertexHit = curr_hit3_new;
        //         float pathLengthNew = other_d01 + length(other_x1.posW - curr_x2.posW) + length(curr_x2.posW - curr_v3_new.posW) 
        //             + length(curr_v3_new.posW - curr_x4.posW);
        //         dst_reservoir.totalPathLength = pathLengthNew;
        //     }
        // }
    }
    
}
