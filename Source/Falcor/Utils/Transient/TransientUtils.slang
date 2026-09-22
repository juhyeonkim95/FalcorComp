#include "Utils/Math/MathConstants.slangh"

#define TIME_GATE_ALL 0
#define TIME_GATE_BOX 1
#define TIME_GATE_TENT 2
#define TIME_GATE_COS 3
#define TIME_GATE_EXP 4
#define TIME_GATE_GAUSSIAN 5
#define TIME_GATE_EPANECHNIKOV 6
#define TIME_GATE_SAWTOOTH 6
#define TIME_GATE_PERLIN 8

cbuffer TimeGate
{
	// used for time-gate
    float time_gate_window;
	float time_gate_window_rough;
    uint time_gate_mode;
    float tcurr;
    float tprev;

	// used for transient
	uint tbin;
	float tmin;
	float tmax;
	float tunit;
};

bool getPathLengthIndex(float distance, out uint idx, out float residual){
	if(distance < tmin || distance > tmax){
		return false; 
	}
	float v = (distance - tmin) / tunit;
	idx = uint(v);
	idx = clamp(idx, 0, tbin - 1);
	residual = frac(v);
	return true;
}

float getMaxpathLength(float target_distance, bool use_rough = false)
{
	float target_time_gate_window = use_rough ? time_gate_window_rough : time_gate_window;
	switch(time_gate_mode)
	{	
		case TIME_GATE_ALL:{
			return FLT_MAX;
		}
		case TIME_GATE_BOX:{
			return target_distance + 0.5 * target_time_gate_window;
		}
		case TIME_GATE_TENT:{
			return target_distance + target_time_gate_window;
		}
		case TIME_GATE_COS:{
			return FLT_MAX;
		}
	}
	return FLT_MAX;
}

/**
 * Evaluate Path Length Importance Function
 */

 float pathLengthImportance(float distance, float target_distance, bool use_rough = false)
 {
	float target_time_gate_window = use_rough ? time_gate_window_rough : time_gate_window;
	float v = (distance - target_distance) / (target_time_gate_window);
	float epsilon = 1e-6;
	// return 0.5 * (cos(M_2PI * v) + 1.0);
    switch(time_gate_mode)
	{	
		case TIME_GATE_ALL:{
			return 1.0;
		}
		case TIME_GATE_BOX:{
			// return abs(v) < 0.5 - epsilon ? 1.0 : (abs(v) > 0.5 + epsilon) ? 0.0 : ((0.5 - abs(v)) / epsilon + 1) * 0.5;
			return abs(v) < 0.5 ? 1.0 : 0.0;
		}
		case TIME_GATE_TENT:{
			return max(1.0 - abs(v), 0.0);
		}
		case TIME_GATE_COS:{
			// return 0.5 * (cos(M_2PI * v) + 1.0);
			return (cos(M_2PI * v));
			// return (cos(M_2PI * (v + time_gate_window_rough)));
		}
	}
	return 1.0;
 }

 /**
 * Evaluate Path Length Importance Function
 */

 float pathLengthImportanceGivenWindow(float distance, float target_distance, float target_time_gate_window)
 {
	float v = (distance - target_distance) / (target_time_gate_window);
	switch(time_gate_mode)
	{	
		case TIME_GATE_ALL:{
			return 1.0;
		}
		case TIME_GATE_BOX:{
			return abs(v) < 0.5 ? 1.0 : 0.0;
		}
		case TIME_GATE_TENT:{
			return max(1.0 - abs(v), 0.0);
		}
		case TIME_GATE_GAUSSIAN:{
			const float sigma = 0.3989422804014327f; // 1/sqrt(2*pi)
			const float invSigma2 = 1.0f / (sigma * sigma);
			return exp(-0.5f * v * v * invSigma2);
		}
        case TIME_GATE_PERLIN:
        {
            // Perlin smoothing profile: 1 - 6u^5 + 15u^4 - 10u^3, 0 <= u <= 1.
            // Hachisuka et al. 2010, Appendix A, Eq. (34).
            // Here window is full support width, as for box/Epanechnikov.
            // Factor 2 normalizes the 1D kernel on v in [-0.5, 0.5].
            float u = 2.f * abs(v);
            if (u >= 1.f) return 0.f;
            float s = 1.f - u;
            // Equivalent factored polynomial avoids cancellation near the boundary.
            return 2.f * s * s * s * (1.f + 3.f * u + 6.f * u * u);
        }
		case TIME_GATE_EPANECHNIKOV:{
			// Support exactly [-0.5, 0.5], integral = 1
			float a = abs(v);
			if (a > 0.5f) return 0.0f;
			float t = 2.0f * v;                 // u = 2v in [-1,1]
			return 1.5f * (1.0f - t * t);       // 2 * (3/4) * (1 - u^2)
		}
	}
	
	return abs(v) < 0.5 ? 1.0 : 0.0;
 }

 inline float tentPdfTime(float tau, float t, float a)
 {
	 float x = abs(tau - t);
	 if (x > a) return 0.0;
	 return (a - x) / (a * a);
 }

 
 // Density of samplePathLength(), including its finite support.
 float evalPdfPathLength(float distance, float target_distance, bool use_rough = false)
 {
    float width = use_rough ? time_gate_window_rough : time_gate_window;
    if (!(width > 0.f)) return 0.f;
    switch (time_gate_mode)
    {
        case TIME_GATE_BOX:
            return abs(distance - target_distance) <= 0.5f * width ? 1.f / width : 0.f;
        case TIME_GATE_TENT:
            return tentPdfTime(distance, target_distance, 0.5f * width);
    }
    return 0.f; // No length sampler is implemented for the other gate modes.
 }

 void samplePathLength(float t, float u, out float tau, out float pdf, bool use_rough = false)
 {
	float target_time_gate_window = use_rough ? time_gate_window_rough : time_gate_window;
	float a = 0.5 * target_time_gate_window;
	tau = t;
	pdf = 0.f;
	if (!(a > 0.f)) return;
	switch(time_gate_mode){
		case TIME_GATE_BOX:{
			tau = t + (2 * u - 1.0) * a;
			pdf = 1.0 / (target_time_gate_window);
			return;
		}
		case TIME_GATE_TENT:{
			float x;
			if (u < 0.5)
			{
				// u ∈ (0, 0.5): x ∈ [-a, 0]
				x = -a + a * sqrt(2.0 * u);
			}
			else
			{
				// u ∈ [0.5, 1): x ∈ [0, a]
				x =  a - a * sqrt(2.0 * (1.0 - u));
			}
			tau = t + x;
			pdf = tentPdfTime(tau, t, a); // equals (a - |x|) / a^2; peak = 1/a = 2/w
			return;
		}
	}
 }