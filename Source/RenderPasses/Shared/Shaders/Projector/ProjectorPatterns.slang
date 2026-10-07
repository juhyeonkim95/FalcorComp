/** Signed patterns shown by the projector (ProjectorLight), with their antithetic maps (AntitheticMIS).

    A pattern is a function of the projector uv in [0,1]^2 with values in [-1, 1]. Its antithetic map sends uv to a
    point where the pattern has the opposite sign; the maps come in inverse pairs chosen with equal probability,
    or are their own inverse. The host picks the pattern with PROJECTOR_PATTERN and sets its parameters in
    ProjectorPatternCB (ProjectorConfig).
*/
#include "Utils/Math/MathConstants.slangh"
import RenderPasses.Shared.Shaders.Utils.Waveform;

#define PROJECTOR_PATTERN_CONSTANT 0
#define PROJECTOR_PATTERN_PERIODIC 1
#define PROJECTOR_PATTERN_GRAY 2
#define PROJECTOR_PATTERN_XOR 3
#define PROJECTOR_PATTERN_CHECKERBOARD 4
#define PROJECTOR_PATTERN_ARBITRARY 5

#define ARBITRARY_MAPPING_NONE 0
#define ARBITRARY_MAPPING_INDEX 1
#define ARBITRARY_MAPPING_INTERVALS 2

#ifndef PROJECTOR_PATTERN
#define PROJECTOR_PATTERN PROJECTOR_PATTERN_CONSTANT
#endif

cbuffer ProjectorPatternCB
{
    uint gPatternAxis;        // Projector coordinate the pattern varies along: 0 = u, 1 = v.
    float gPatternSign;       // -1 inverts the pattern.
    uint gPatternUnsigned;    // Show 0.5 p + 0.5 instead of p.

    uint gPatternWaveform;    // Periodic: WAVEFORM_* (Waveform.slang).
    float gPatternWavelength; // Periodic: period in uv units.
    float gPatternPhase;      // Periodic: offset in periods, subtracted as for CW-ToF: w(coord / wavelength - phase).

    uint gPatternBits;   // Gray, XOR: 2^bits columns.
    uint gPatternBit;    // Gray, XOR: bit shown, 0 = finest.
    uint gPatternBaseBit; // XOR: base bit (0 = XOR-02, 1 = XOR-04, ...).

    uint2 gCheckerCells; // Checkerboard: cells along u and v.
    uint gCheckerShift;  // Checkerboard: sub-cell shift index, 0..24.

    uint gArbitraryWidth;   // Arbitrary: columns.
    uint gArbitraryMapping; // Arbitrary: ARBITRARY_MAPPING_*.
}

Texture1D<uint> gPatternValues;   // Arbitrary: 0 or 1 per column.
Texture1D<uint> gAntitheticIndex; // Arbitrary, index mapping: column matched to each column, of the opposite value.
Texture1D<uint> gIntervalIds;     // Arbitrary, interval mapping: interval of each column.
Texture1D<uint> gIntervals;       // Arbitrary, interval mapping: (srcStart, srcEnd, dstStart, dstEnd) per interval.

interface IProjectorPattern
{
    /// Pattern value at uv, in [-1, 1].
    float eval(float2 uv);

    /// Antithetic partner of uv. `u` in [0,1) picks one of the maps.
    float2 antitheticCoord(float2 uv, float u);

    /// |d(partner coordinate) / d(coordinate)| along the pattern axis.
    float antitheticJacobian(float2 uv);
};

float axisCoord(float2 uv)
{
    return gPatternAxis == 0 ? uv.x : uv.y;
}

float2 withAxisCoord(float2 uv, float coord)
{
    if (gPatternAxis == 0)
        uv.x = coord;
    else
        uv.y = coord;
    return uv;
}

/// Column of uv along the pattern axis, for a pattern `width` columns wide.
uint axisColumn(float2 uv, uint width)
{
    return min(uint(clamp(axisCoord(uv), 0.f, 0.999999f) * float(width)), width - 1u);
}

/// Swaps the two halves of each block of `2 * halfBlock` columns (its own inverse).
float2 swapHalfBlocks(float2 uv, uint width, float halfBlock)
{
    float coord = clamp(axisCoord(uv), 0.f, 0.999999f) * float(width);
    float local = coord - floor(coord / (2.f * halfBlock)) * (2.f * halfBlock);
    float coordAnti = local < halfBlock ? coord + halfBlock : coord - halfBlock;
    return withAxisCoord(uv, clamp(coordAnti / float(width), 0.f, 0.999999f));
}

/// Gray code of column `index`, bit `bit`.
uint grayBit(uint index, uint bit)
{
    return ((index ^ (index >> 1)) >> bit) & 1u;
}

/// Uniform illumination (no antithetic partner: the map is the identity).
struct ConstantPattern : IProjectorPattern
{
    float eval(float2 uv) { return 1.f; }
    float2 antitheticCoord(float2 uv, float u) { return uv; }
    float antitheticJacobian(float2 uv) { return 1.f; }
};

/// Periodic stripes along the pattern axis, with zero mean over a period.
struct PeriodicPattern : IProjectorPattern
{
    /// Position in the pattern, in periods.
    float periods(float2 uv) { return axisCoord(uv) / gPatternWavelength - gPatternPhase; }

    float eval(float2 uv) { return evalWaveform(gPatternWaveform, periods(uv)); }

    /// Mirror image within the period (mirrorWaveformOffset), its own inverse.
    float2 antitheticCoord(float2 uv, float u)
    {
        return withAxisCoord(uv, axisCoord(uv) + mirrorWaveformOffset(gPatternWaveform, periods(uv)) * gPatternWavelength);
    }

    float antitheticJacobian(float2 uv) { return 1.f; }
};

/// One bit of the Gray code of the column index, over 2^gPatternBits columns.
struct GrayPattern : IProjectorPattern
{
    uint width() { return 1u << gPatternBits; }

    float eval(float2 uv) { return grayBit(axisColumn(uv, width()), gPatternBit) != 0 ? 1.f : -1.f; }

    /// Moving by 2^bit columns within a block of 2^(bit + 1) flips that Gray bit.
    float2 antitheticCoord(float2 uv, float u) { return swapHalfBlocks(uv, width(), float(1u << gPatternBit)); }

    float antitheticJacobian(float2 uv) { return 1.f; }
};

/// XOR code: a Gray bit XORed with a high-frequency base bit (XOR-02, XOR-04, ...), after Gupta et al. 2012.
struct XORPattern : IProjectorPattern
{
    uint width() { return 1u << gPatternBits; }

    float eval(float2 uv)
    {
        uint column = axisColumn(uv, width());
        uint value = grayBit(column, gPatternBit);
        if (gPatternBit > gPatternBaseBit)
            value ^= grayBit(column, gPatternBaseBit);
        if (gPatternBit > gPatternBits)
            return 1.f;
        return value != 0 ? 1.f : -1.f;
    }

    /// Moving within a block of 2^(baseBit + 1) columns flips the base bit.
    float2 antitheticCoord(float2 uv, float u) { return swapHalfBlocks(uv, width(), float(1u << gPatternBaseBit)); }

    float antitheticJacobian(float2 uv) { return 1.f; }
};

/// Binary checkerboard of gCheckerCells cells, shifted by gCheckerShift fifths of a cell.
struct CheckerboardPattern : IProjectorPattern
{
    static const uint kShiftSteps = 5u;

    float2 shift()
    {
        float2 steps = float2(float(gCheckerShift % kShiftSteps), float(gCheckerShift / kShiftSteps));
        return steps / float(kShiftSteps) / float2(gCheckerCells);
    }

    float eval(float2 uv)
    {
        float2 shifted = clamp(frac(uv + shift()), 0.f, 0.999999f);
        uint2 cell = min(uint2(shifted * float2(gCheckerCells)), gCheckerCells - 1u);
        return ((cell.x + cell.y) & 1u) != 0 ? 1.f : -1.f;
    }

    /// One cell left, right, down or up, with equal probability (two inverse pairs), wrapping around.
    float2 antitheticCoord(float2 uv, float u)
    {
        uint direction = min(uint(clamp(u, 0.f, 0.999999f) * 4.f), 3u);
        float2 step = float2(0.f);
        if (direction == 0u) step.x = -1.f;
        else if (direction == 1u) step.x = 1.f;
        else if (direction == 2u) step.y = -1.f;
        else step.y = 1.f;
        return frac(uv + step / float2(gCheckerCells));
    }

    float antitheticJacobian(float2 uv) { return 1.f; }
};

/// Binary pattern from the host (gPatternValues), with the antithetic map given as a column matching
/// (gAntitheticIndex) or as intervals mapped linearly onto intervals (gIntervalIds, gIntervals).
struct ArbitraryPattern : IProjectorPattern
{
    float eval(float2 uv) { return gPatternValues.Load(int2(axisColumn(uv, gArbitraryWidth), 0)) != 0 ? 1.f : -1.f; }

    void loadInterval(float2 uv, out float srcStart, out float srcLength, out float dstStart, out float dstLength)
    {
        uint base = gIntervalIds.Load(int2(axisColumn(uv, gArbitraryWidth), 0)) * 4u;
        srcStart = float(gIntervals.Load(int2(base + 0, 0)));
        srcLength = max(float(gIntervals.Load(int2(base + 1, 0))) - srcStart, 1.f);
        dstStart = float(gIntervals.Load(int2(base + 2, 0)));
        dstLength = max(float(gIntervals.Load(int2(base + 3, 0))) - dstStart, 1.f);
    }

    float2 antitheticCoord(float2 uv, float u)
    {
        float coord = clamp(axisCoord(uv), 0.f, 0.999999f) * float(gArbitraryWidth);
        float coordAnti = coord;
        if (gArbitraryMapping == ARBITRARY_MAPPING_INDEX)
        {
            uint column = min(uint(coord), gArbitraryWidth - 1u);
            coordAnti = float(gAntitheticIndex.Load(int2(column, 0))) + frac(coord);
        }
        else if (gArbitraryMapping == ARBITRARY_MAPPING_INTERVALS)
        {
            float srcStart, srcLength, dstStart, dstLength;
            loadInterval(uv, srcStart, srcLength, dstStart, dstLength);
            coordAnti = dstStart + clamp((coord - srcStart) / srcLength, 0.f, 0.999999f) * dstLength;
        }
        return withAxisCoord(uv, clamp(coordAnti / float(gArbitraryWidth), 0.f, 0.999999f));
    }

    float antitheticJacobian(float2 uv)
    {
        if (gArbitraryMapping != ARBITRARY_MAPPING_INTERVALS)
            return 1.f;
        float srcStart, srcLength, dstStart, dstLength;
        loadInterval(uv, srcStart, srcLength, dstStart, dstLength);
        return dstLength / srcLength;
    }
};

#if PROJECTOR_PATTERN == PROJECTOR_PATTERN_PERIODIC
typealias ProjectorPattern = PeriodicPattern;
#elif PROJECTOR_PATTERN == PROJECTOR_PATTERN_GRAY
typealias ProjectorPattern = GrayPattern;
#elif PROJECTOR_PATTERN == PROJECTOR_PATTERN_XOR
typealias ProjectorPattern = XORPattern;
#elif PROJECTOR_PATTERN == PROJECTOR_PATTERN_CHECKERBOARD
typealias ProjectorPattern = CheckerboardPattern;
#elif PROJECTOR_PATTERN == PROJECTOR_PATTERN_ARBITRARY
typealias ProjectorPattern = ArbitraryPattern;
#else
typealias ProjectorPattern = ConstantPattern;
#endif
