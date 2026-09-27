/** Transient histogram: tbin bins of width tunit over the path lengths [tmin, tmax). The host sets the
    TransientHistogram constants (TransientHistogramConfig).
*/

cbuffer TransientHistogram
{
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
