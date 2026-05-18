#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

export struct GrayPattern : IProjectorPattern
{
    uint totalBits;   // e.g. 10 -> 1024 columns
    uint currentBit;  // 0 = highest frequency (LSB)
    bool useVertical;  // false: use uv.x (vertical stripes)    
                       // true : use uv.y (horizontal stripes)
    
    uint width()
    {
        return 1u << totalBits;
    }

    float getCoord(float2 uv)
    {
        return useVertical ? uv.y : uv.x;
    }

    uint uvToIndex(float2 uv)
    {
        uint W = width();
        float t = clamp(getCoord(uv), 0.0f, 0.999999f);
        return min((uint)floor(t * float(W)), W - 1u);
    }

    uint grayCode(uint idx)
    {
        return idx ^ (idx >> 1);
    }

    uint grayBit(uint idx, uint bit)
    {
        uint g = grayCode(idx);
        return (g >> bit) & 1u;
    }

    float eval(float2 uv)
    {
        uint idx = uvToIndex(uv);
        uint v = grayBit(idx, currentBit);
        return 2.0f * float(v) - 1.0f; // [-1, +1]
    }

    float2 antitheticCoord(float2 uv, float r)
    {
        uint W = width();

        float coord = clamp(getCoord(uv), 0.0f, 0.999999f) * float(W);

        float halfBlock = float(1u << currentBit);
        float fullBlock = 2.0f * halfBlock;

        float blockStart = floor(coord / fullBlock) * fullBlock;
        float local = coord - blockStart;

        float coordAnti = (local < halfBlock)
                        ? coord + halfBlock
                        : coord - halfBlock;

        coordAnti = clamp(coordAnti / float(W), 0.0f, 0.999999f);

        float2 uv2 = uv;
        if (useVertical)
            uv2.y = coordAnti;
        else
            uv2.x = coordAnti;

        return uv2;
    }
    float antitheticJacobian(float2 uv){return 1.0;}
};