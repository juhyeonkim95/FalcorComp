// Running mean of a transient histogram (width x height x bins), the 3D counterpart of AccumulatePass.

cbuffer CB
{
    uint3 gDim;
    uint gFrameCount; // frames averaged, including this one (>= 1)
}

#if SINGLE_CHANNEL
typedef float Value;
#else
typedef float4 Value;
#endif

Texture3D<Value> gInput;
RWTexture3D<Value> gMean;
RWTexture3D<Value> gCompensation; // COMPENSATED only
RWTexture3D<Value> gOutput;

[numthreads(8, 8, 4)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint3 index = dispatchThreadId;
    if (any(index >= gDim))
        return;

    Value value = gInput[index];
    Value mean = value;
    if (gFrameCount <= 1)
    {
#if COMPENSATED
        gCompensation[index] = Value(0.f);
#endif
    }
    else
    {
        // mean_n = mean_{n-1} + (x_n - mean_{n-1}) / n
        Value previous = gMean[index];
        Value increment = (value - previous) / float(gFrameCount);
#if COMPENSATED
        // Kahan summation of the increments.
        Value corrected = increment - gCompensation[index];
        mean = previous + corrected;
        gCompensation[index] = (mean - previous) - corrected;
#else
        mean = previous + increment;
#endif
    }
    gMean[index] = mean;
    gOutput[index] = mean;
}
