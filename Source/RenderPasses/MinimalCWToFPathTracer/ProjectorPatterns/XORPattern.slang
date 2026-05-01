#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

export struct XORPattern : IProjectorPattern
{
    uint totalBits;   // e.g. 10 -> 1024 columns
    uint currentBit;  // 0 = highest frequency / LSB Gray bit
    uint baseBit;     // 0 = XOR-02, 1 = XOR-04, 2 = XOR-08, ...
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

    uint uvToCol(float2 uv)
    {
        uint W = width();
        float u = clamp(getCoord(uv), 0.0f, 0.999999f);
        return min((uint)floor(u * float(W)), W - 1u);
    }

    uint grayCode(uint col)
    {
        return col ^ (col >> 1);
    }

    uint grayBit(uint col, uint bit)
    {
        uint g = grayCode(col);
        return (g >> bit) & 1u;
    }

    float colToU(uint col)
    {
        uint W = width();
        return (float(col) + 0.5f) / float(W);
    }

    float eval(float2 uv)
    {
        uint col = uvToCol(uv);

        uint v = grayBit(col, currentBit);

        // XOR-k construction:
        // XOR-02: baseBit = 0
        // XOR-04: baseBit = 1
        // XOR-08: baseBit = 2
        if (currentBit > baseBit)
        {
            v = v ^ grayBit(col, baseBit);
        }
        if(currentBit > totalBits){
            return 1.0f;
        }

        return 2.0f * float(v) - 1.0f; // 0/1 -> -1/+1
    }

    float2 antitheticCoord(float2 uv, float r)
    {
        uint W = width();

        float x = clamp(getCoord(uv), 0.0f, 0.999999f) * float(W);

        // XOR-02: full block = 2 pixels, half = 1
        // XOR-04: full block = 4 pixels, half = 2
        // XOR-08: full block = 8 pixels, half = 4
        float fullBlock = float(1u << (baseBit + 1u));
        float halfBlock = 0.5f * fullBlock;

        float blockStart = floor(x / fullBlock) * fullBlock;
        float local = x - blockStart;

        float xAnti = (local < halfBlock) ? x + halfBlock : x - halfBlock;

        float2 uvAnti = uv;
        if(useVertical){
            uvAnti.y = clamp(xAnti / float(W), 0.0f, 0.999999f);
        } else {
            uvAnti.x = clamp(xAnti / float(W), 0.0f, 0.999999f);
        }
        
        return uvAnti;
    }
    float antitheticJacobian(float2 uv){return 1.0;}
};