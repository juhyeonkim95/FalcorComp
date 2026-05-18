#include "Utils/Math/MathConstants.slangh"
import Utils.Math.MathHelpers;
import ProjectorPatternInterface;

// Simple 2D binary checkerboard pattern.
// flip:
//   0 = all white
//   1 = checkerboard
//   2 = flipped checkerboard
export struct CheckerboardPattern : IProjectorPattern
{
    uint cellsU;
    uint cellsV;
    uint flip;
    uint shiftIndex; // 0,...,24

    static const uint shiftN = 5u;

    float2 shiftedUV(float2 uv)
    {
        uint sx = shiftIndex % shiftN;
        uint sy = shiftIndex / shiftN;

        // shift inside one checker cell
        float2 shift = float2(float(sx), float(sy)) / float(shiftN);
        float2 cellCount = float2(float(cellsU), float(cellsV));

        return frac(uv + shift / cellCount);
    }

    uint2 uvToCell(float2 uv)
    {
        uv = shiftedUV(uv);

        float u = clamp(uv.x, 0.0f, 0.999999f);
        float v = clamp(uv.y, 0.0f, 0.999999f);

        uint i = min((uint)floor(u * float(cellsU)), cellsU - 1u);
        uint j = min((uint)floor(v * float(cellsV)), cellsV - 1u);

        return uint2(i, j);
    }

    float eval(float2 uv)
    {
        if (flip == 0u)
            return 1.0f; // all white

        uint2 cell = uvToCell(uv);

        uint bit = (cell.x + cell.y) & 1u;

        if (flip == 2u)
            bit = 1u - bit;

        return 2.0f * float(bit) - 1.0f; // 0 -> -1, 1 -> +1
    }

    float2 antitheticCoord(float2 uv, float r)
    {
        // Important: antithetic mapping should be defined in shifted checker space.
        float2 uvS = shiftedUV(uv);

        float2 cellSize = 1.0f / float2(float(cellsU), float(cellsV));

        float2 coord = uvS / cellSize;
        uint2 cell = uint2(
            min((uint)floor(coord.x), cellsU - 1u),
            min((uint)floor(coord.y), cellsV - 1u)
        );

        float2 local = frac(coord);

        uint dir = min((uint)floor(clamp(r, 0.0f, 0.999999f) * 4.0f), 3u);

        int di = 0;
        int dj = 0;

        if (dir == 0u)      di = -1; // left
        else if (dir == 1u) di =  1; // right
        else if (dir == 2u) dj = -1; // bottom
        else                dj =  1; // top

        uint i2 = (uint)((int(cell.x) + di + int(cellsU)) % int(cellsU));
        uint j2 = (uint)((int(cell.y) + dj + int(cellsV)) % int(cellsV));

        float2 uvS2;
        uvS2.x = (float(i2) + local.x) / float(cellsU);
        uvS2.y = (float(j2) + local.y) / float(cellsV);

        // Convert back from shifted checker space to original uv space.
        uint sx = shiftIndex % shiftN;
        uint sy = shiftIndex / shiftN;

        float2 shift = float2(float(sx), float(sy)) / float(shiftN);
        float2 cellCount = float2(float(cellsU), float(cellsV));

        return frac(uvS2 - shift / cellCount);
    }

    float antitheticJacobian(float2 uv)
    {
        return 1.0f;
    }
};