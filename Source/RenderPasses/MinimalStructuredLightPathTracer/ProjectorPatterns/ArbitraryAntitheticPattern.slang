#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

cbuffer CB_pattern
{   
    Texture1D<uint> patternTex;       // 0 or 1

    // used for antithetic sampling based on optimal transport
    Texture1D<uint> antiIndex;   // antiIndex[i] = matched opposite-bit index

    // used for antithetic sampling based on scaling mapping
    Texture1D<uint> intervalIdTex;    // per-pixel interval id
    Texture1D<uint> intervalTex;      // flattened intervals (4 * numIntervals)
}

export struct ArbitraryAntitheticPattern : IProjectorPattern
{
    uint width;
    bool useVertical;
    bool useOTMapping;

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
        return 2.0f * float(v) - 1.0f;
    }

    void loadInterval(uint intervalId,
                      out float srcStart,
                      out float srcEnd,
                      out float dstStart,
                      out float dstEnd)
    {
        uint base = intervalId * 4u;

        srcStart = float(intervalTex.Load(int2(base + 0, 0)));
        srcEnd   = float(intervalTex.Load(int2(base + 1, 0)));
        dstStart = float(intervalTex.Load(int2(base + 2, 0)));
        dstEnd   = float(intervalTex.Load(int2(base + 3, 0)));
    }

    float2 antitheticCoord(float2 uv, float r)
    {
        float coord = clamp(getCoord(uv), 0.0f, 0.999999f) * float(width);

        uint idx = min((uint)floor(coord), width - 1u);
        
        float coordAnti = coord;
        if(useOTMapping){
            float local = frac(coord);
            uint idxAnti = antiIndex.Load(int2(idx, 0));
            coordAnti = (float(idxAnti) + local) / float(width);
            
        } else {
            uint intervalId = intervalIdTex.Load(int2(idx, 0));

            float srcStart, srcEnd, dstStart, dstEnd;
            loadInterval(intervalId, srcStart, srcEnd, dstStart, dstEnd);

            float srcLen = max(srcEnd - srcStart, 1.0f);
            float dstLen = max(dstEnd - dstStart, 1.0f);

            float local = (coord - srcStart) / srcLen;
            local = clamp(local, 0.0f, 0.999999f);

            coordAnti = (dstStart + local * dstLen) / float(width);
        }
        coordAnti = clamp(coordAnti, 0.0f, 0.999999f);

        float2 uv2 = uv;
        if (useVertical)
            uv2.y = coordAnti;
        else
            uv2.x = coordAnti;

        return uv2;
    }

    float antitheticJacobian(float2 uv)
    {
        if(useOTMapping) return 1.0;

        uint idx = uvToIndex(uv);
        uint intervalId = intervalIdTex.Load(int2(idx, 0));

        float srcStart, srcEnd, dstStart, dstEnd;
        loadInterval(intervalId, srcStart, srcEnd, dstStart, dstEnd);

        float srcLen = max(srcEnd - srcStart, 1.0f);
        float dstLen = max(dstEnd - dstStart, 1.0f);

        return dstLen / srcLen;
    }
};