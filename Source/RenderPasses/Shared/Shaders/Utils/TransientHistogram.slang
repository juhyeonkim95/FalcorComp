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
