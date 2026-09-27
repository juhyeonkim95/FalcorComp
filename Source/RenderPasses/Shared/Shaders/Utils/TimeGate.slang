/** Time gates: a kernel over the optical path length, centered on the gate center with width time_gate_window, and
    samplers for path lengths inside it. The host picks the kernel with time_gate_mode (Shared/Host/Configs/TimeGate.h)
    and sets the TimeGate constants (TimeGateConfig).
*/
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;

#define TIME_GATE_ALL 0
#define TIME_GATE_BOX 1
#define TIME_GATE_TENT 2
#define TIME_GATE_COS 3
#define TIME_GATE_EXP 4
#define TIME_GATE_GAUSSIAN 5
#define TIME_GATE_EPANECHNIKOV 6
#define TIME_GATE_PERLIN 8
#define TIME_GATE_EXP_TWO_SIDE 9

cbuffer TimeGate
{
    float time_gate_window;
    float time_gate_window_rough;
    uint time_gate_mode;
    float tcurr;
    float tprev;
};

// Gaussian and exponential gates, in gate widths v = (length - center) / width. Both are truncated and
// renormalized to unit integral, like the box and the tent, so the gated image keeps the same scale.
// Gaussian: exp(-pi v^2) (sigma = 1 / sqrt(2 pi) widths), truncated at 3 sigma.
static const float kGaussianGateHalfWidth = 1.19682684f; // 3 sigma, in gate widths
static const float kGaussianGateMass = 0.99730020f;      // erf(3 / sqrt(2)): integral of exp(-pi v^2) over |v| <= 3 sigma
// Exponential: one-sided exp(-v) for 0 <= v <= 3 widths; it opens at the center and decays.
static const float kExponentialGateLength = 3.f;
static const float kExponentialGateMass = 0.95021293f;   // 1 - exp(-3)
// Two-sided exponential: exp(-2 |v|) (decays over half a width on each side), truncated at 3 decay lengths.
static const float kExpTwoSideGateHalfWidth = 1.5f;
static const float kExpTwoSideGateMass = 0.95021293f;    // 1 - exp(-3): integral of exp(-2 |v|) over |v| <= 1.5

float gaussianGate(float v)
{
	return abs(v) <= kGaussianGateHalfWidth ? exp(-M_PI * v * v) / kGaussianGateMass : 0.f;
}

float exponentialGate(float v)
{
	return (v >= 0.f && v <= kExponentialGateLength) ? exp(-v) / kExponentialGateMass : 0.f;
}

float exponentialTwoSideGate(float v)
{
	return abs(v) <= kExpTwoSideGateHalfWidth ? exp(-2.f * abs(v)) / kExpTwoSideGateMass : 0.f;
}

float getMaxPathLength(float target_distance, bool use_rough = false)
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
		case TIME_GATE_GAUSSIAN:{
			return target_distance + kGaussianGateHalfWidth * target_time_gate_window;
		}
		case TIME_GATE_EXP:{
			return target_distance + kExponentialGateLength * target_time_gate_window;
		}
		case TIME_GATE_EXP_TWO_SIDE:{
			return target_distance + kExpTwoSideGateHalfWidth * target_time_gate_window;
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
		case TIME_GATE_COS:{
			return (cos(M_2PI * v));
		}
		case TIME_GATE_GAUSSIAN:{
			return gaussianGate(v);
		}
		case TIME_GATE_EXP:{
			return exponentialGate(v);
		}
		case TIME_GATE_EXP_TWO_SIDE:{
			return exponentialTwoSideGate(v);
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
        case TIME_GATE_GAUSSIAN:
            return gaussianGate((distance - target_distance) / width) / width;
        case TIME_GATE_EXP:
            return exponentialGate((distance - target_distance) / width) / width;
        case TIME_GATE_EXP_TWO_SIDE:
            return exponentialTwoSideGate((distance - target_distance) / width) / width;
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
		case TIME_GATE_GAUSSIAN:{
			// Inverse CDF of the truncated Gaussian: v = sigma sqrt(2) erfinv(u'), u' uniform in +-erf(3 / sqrt(2)).
			float v = M_1_SQRTPI * erfinv((2.f * u - 1.f) * kGaussianGateMass);
			tau = t + v * target_time_gate_window;
			pdf = gaussianGate(v) / target_time_gate_window;
			return;
		}
		case TIME_GATE_EXP:{
			// Inverse CDF of the truncated exponential on [0, 3] widths.
			float v = -log(1.f - u * kExponentialGateMass);
			tau = t + v * target_time_gate_window;
			pdf = exponentialGate(v) / target_time_gate_window;
			return;
		}
		case TIME_GATE_EXP_TWO_SIDE:{
			// Pick a side with the first half of u, then invert the truncated exponential on [0, 3] decay
			// lengths (half widths).
			float side = u < 0.5f ? 1.f : -1.f;
			float w = u < 0.5f ? 2.f * u : 2.f * u - 1.f;
			float v = side * 0.5f * -log(1.f - w * kExpTwoSideGateMass);
			tau = t + v * target_time_gate_window;
			pdf = exponentialTwoSideGate(v) / target_time_gate_window;
			return;
		}
	}
 }