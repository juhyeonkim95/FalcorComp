#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

cbuffer CB_pattern
{
    Texture1D<uint> patternTex;  // 0 or 1
    Texture1D<uint> antiIndex;   // antiIndex[i] = matched opposite-bit index
}



export struct OTBitFlipPattern : IProjectorPattern
{
    
    uint width;        // number of bins / pixels in 1D pattern
    bool useVertical;  // false: use uv.x, true: use uv.y

    float getCoord(float2 uv)
    {
        return useVertical ? uv.y : uv.x;
    }

    uint uvToIndex(float2 uv)
    {
        float t = clamp(getCoord(uv), 0.0f, 0.999999f);
        return min((uint)floor(t * float(width)), width - 1u);
    }

    float eval(float2 uv)
    {
        uint idx = uvToIndex(uv);
        uint v = patternTex.Load(int2(idx, 0));
        return 2.0f * float(v) - 1.0f; // 0 -> -1, 1 -> +1
    }

    float2 antitheticCoord(float2 uv, float r)
    {
        float coord = clamp(getCoord(uv), 0.0f, 0.999999f) * float(width);

        uint idx = min((uint)floor(coord), width - 1u);
        float local = frac(coord);

        uint idxAnti = antiIndex.Load(int2(idx, 0));

        float coordAnti = (float(idxAnti) + local) / float(width);
        coordAnti = clamp(coordAnti, 0.0f, 0.999999f);

        float2 uv2 = uv;
        if (useVertical)
            uv2.y = coordAnti;
        else
            uv2.x = coordAnti;

        return uv2;
    }
    float antitheticJacobian(float2 uv){return 1.0;}
};