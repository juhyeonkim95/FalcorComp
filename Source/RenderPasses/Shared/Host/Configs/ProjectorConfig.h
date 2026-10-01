#pragma once
#include "ConfigUtils.h"
#include "Waveform.h"
#include "RenderGraph/RenderPass.h"
#include <cmath>
#include <vector>

/// Pattern shown by the projector (PROJECTOR_PATTERN in Shared/Shaders/Projector/ProjectorPatterns.slang).
enum class ProjectorPatternType : uint32_t
{
    Constant = 0,
    Periodic = 1,
    Gray = 2,
    XOR = 3,
    Checkerboard = 4,
    Arbitrary = 5,
};

inline const std::unordered_map<std::string, ProjectorPatternType> kProjectorPatternTypes = {
    {"constant", ProjectorPatternType::Constant},
    {"periodic", ProjectorPatternType::Periodic},
    {"gray", ProjectorPatternType::Gray},
    {"xor", ProjectorPatternType::XOR},
    {"checkerboard", ProjectorPatternType::Checkerboard},
    {"arbitrary", ProjectorPatternType::Arbitrary},
};

/// Projector coordinate the pattern varies along.
enum class PatternAxis : uint32_t
{
    U = 0,
    V = 1,
};

inline const std::unordered_map<std::string, PatternAxis> kPatternAxes = {
    {"u", PatternAxis::U},
    {"v", PatternAxis::V},
};

/// Pinhole projector with a signed pattern (Shared/Shaders/Projector). u runs along the projector's right and v
/// along its up, both over [0, 1] across the field of view.
struct ProjectorConfig
{
    float3 position = float3(0.f);
    float3 direction = float3(0.f, 0.f, -1.f);
    float3 up = float3(0.f, 1.f, 0.f); ///< Up hint; the projector's up is made orthogonal to the direction.
    float2 fov = float2(22.62f);       ///< Full field of view along u and v, in degrees.
    float3 intensity = float3(10.f);

    ProjectorPatternType pattern = ProjectorPatternType::Periodic;
    PatternAxis patternAxis = PatternAxis::U;
    bool invertPattern = false;
    bool unsignedModulation = false; ///< Show 0.5 p + 0.5 in [0, 1] instead of the zero-mean p in [-1, 1].
    Waveform waveform = Waveform::Cos;                      ///< Periodic.
    float patternWavelength = 0.05f;                       ///< Periodic: period, in uv units.
    float patternPhase = 0.f;                              ///< Periodic: offset, in periods.
    uint patternBits = 10;                                 ///< Gray, XOR: 2^bits columns.
    uint patternBit = 0;                                   ///< Gray, XOR: bit shown, 0 = finest.
    uint patternBaseBit = 0;                               ///< XOR: base bit (0 = XOR-02, 1 = XOR-04, ...).
    uint2 checkerCells = uint2(16);                        ///< Checkerboard: cells along u and v.
    uint checkerShift = 0;                                 ///< Checkerboard: sub-cell shift index, 0..24.

    void validate() const
    {
        if (!(length(direction) > 0.f) || !(length(cross(direction, up)) > 0.f))
            FALCOR_THROW("projectorDirection must be nonzero and not parallel to projectorUp.");
        if (!(fov.x > 0.f && fov.x < 180.f && fov.y > 0.f && fov.y < 180.f))
            FALCOR_THROW("projectorFov must be in (0, 180) degrees.");
        if (!std::isfinite(patternWavelength) || patternWavelength <= 0.f)
            FALCOR_THROW("patternWavelength must be finite and greater than zero.");
        if (patternBits == 0 || patternBits > 24)
            FALCOR_THROW("patternBits must be in [1, 24].");
        if (checkerCells.x == 0 || checkerCells.y == 0)
            FALCOR_THROW("checkerCells must be greater than zero.");
        if (checkerShift >= 25)
            FALCOR_THROW("checkerShift must be in [0, 24].");
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "projectorPosition")
            position = value;
        else if (key == "projectorDirection")
            direction = value;
        else if (key == "projectorUp")
            up = value;
        else if (key == "projectorFov")
            fov = value;
        else if (key == "projectorIntensity")
            intensity = value;
        else if (key == "pattern")
            pattern = parseEnumProperty(kProjectorPatternTypes, value, key);
        else if (key == "patternAxis")
            patternAxis = parseEnumProperty(kPatternAxes, value, key);
        else if (key == "invertPattern")
            invertPattern = value;
        else if (key == "unsignedModulation")
            unsignedModulation = value;
        else if (key == "waveform")
            waveform = parseEnumProperty(kWaveforms, value, key);
        else if (key == "patternWavelength")
            patternWavelength = value;
        else if (key == "patternPhase")
            patternPhase = value;
        else if (key == "patternBits")
            patternBits = value;
        else if (key == "patternBit")
            patternBit = value;
        else if (key == "patternBaseBit")
            patternBaseBit = value;
        else if (key == "checkerCells")
            checkerCells = value;
        else if (key == "checkerShift")
            checkerShift = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["projectorPosition"] = position;
        props["projectorDirection"] = direction;
        props["projectorUp"] = up;
        props["projectorFov"] = fov;
        props["projectorIntensity"] = intensity;
        props["pattern"] = enumPropertyName(kProjectorPatternTypes, pattern);
        props["patternAxis"] = enumPropertyName(kPatternAxes, patternAxis);
        props["invertPattern"] = invertPattern;
        props["unsignedModulation"] = unsignedModulation;
        props["waveform"] = enumPropertyName(kWaveforms, waveform);
        props["patternWavelength"] = patternWavelength;
        props["patternPhase"] = patternPhase;
        props["patternBits"] = patternBits;
        props["patternBit"] = patternBit;
        props["patternBaseBit"] = patternBaseBit;
        props["checkerCells"] = checkerCells;
        props["checkerShift"] = checkerShift;
    }

    /// PROJECTOR_PATTERN.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("PROJECTOR_PATTERN", std::to_string((uint32_t)pattern));
        return defines;
    }

    /// Sets the Projector and ProjectorPatternCB constants under `var` (the root).
    void bindShaderData(const ShaderVar& var) const
    {
        const float3 forward = normalize(direction);
        const float3 right = normalize(cross(forward, up));
        const float3 projectorUp = cross(right, forward);
        auto projectorVar = var["Projector"];
        projectorVar["gProjectorPosition"] = position;
        projectorVar["gProjectorForward"] = forward;
        projectorVar["gProjectorRight"] = right;
        projectorVar["gProjectorUp"] = projectorUp;
        projectorVar["gProjectorTanHalfFov"] = float2(std::tan(math::radians(0.5f * fov.x)), std::tan(math::radians(0.5f * fov.y)));
        projectorVar["gProjectorIntensity"] = intensity;

        auto patternVar = var["ProjectorPatternCB"];
        patternVar["gPatternAxis"] = uint(patternAxis);
        patternVar["gPatternSign"] = invertPattern ? -1.f : 1.f;
        patternVar["gUnsignedModulation"] = uint(unsignedModulation);
        patternVar["gWaveform"] = uint(waveform);
        patternVar["gWavelength"] = patternWavelength;
        patternVar["gPhase"] = patternPhase;
        patternVar["gPatternBits"] = patternBits;
        patternVar["gPatternBit"] = patternBit;
        patternVar["gPatternBaseBit"] = patternBaseBit;
        patternVar["gCheckerCells"] = checkerCells;
        patternVar["gCheckerShift"] = checkerShift;
    }

    /// Position, direction, field of view and intensity.
    bool renderProjectorUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        dirty |= widget.var("Position", position);
        widget.tooltip("Projector center, in world space.", true);
        dirty |= widget.var("Direction", direction, -1.f, 1.f);
        widget.tooltip("Viewing direction of the projector (normalized when used).", true);
        dirty |= widget.var("Up", up, -1.f, 1.f);
        widget.tooltip("Up hint: v runs along it, made orthogonal to the direction.", true);
        dirty |= widget.var("Field of view (deg)", fov, 1.f, 179.f);
        widget.tooltip("Full field of view along u and v, in degrees.", true);
        dirty |= widget.var("Intensity", intensity, 0.f, 1e6f);
        widget.tooltip("Radiant intensity along the projector axis, per color channel.", true);
        return dirty;
    }

    /// Pattern type and its parameters.
    bool renderPatternUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        static const Gui::DropdownList kPatternList = {
            {(uint32_t)ProjectorPatternType::Constant, "Constant"},
            {(uint32_t)ProjectorPatternType::Periodic, "Periodic"},
            {(uint32_t)ProjectorPatternType::Gray, "Gray code"},
            {(uint32_t)ProjectorPatternType::XOR, "XOR code"},
            {(uint32_t)ProjectorPatternType::Checkerboard, "Checkerboard"},
            {(uint32_t)ProjectorPatternType::Arbitrary, "Arbitrary (set_pattern_data)"},
        };
        uint32_t type = (uint32_t)pattern;
        if (widget.dropdown("Pattern", kPatternList, type))
        {
            pattern = (ProjectorPatternType)type;
            dirty = true;
        }
        widget.tooltip("Signed pattern in [-1, 1] shown by the projector. Arbitrary patterns are set from Python "
                       "with set_pattern_data().", true);

        if (pattern != ProjectorPatternType::Constant && pattern != ProjectorPatternType::Checkerboard)
        {
            static const Gui::DropdownList kAxisList = {{(uint32_t)PatternAxis::U, "u"}, {(uint32_t)PatternAxis::V, "v"}};
            uint32_t axis = (uint32_t)patternAxis;
            if (widget.dropdown("Axis", kAxisList, axis))
            {
                patternAxis = (PatternAxis)axis;
                dirty = true;
            }
            widget.tooltip("Projector coordinate the pattern varies along (u: right, v: up).", true);
        }
        dirty |= widget.checkbox("Invert", invertPattern);
        widget.tooltip("Negate the pattern.", true);
        dirty |= widget.checkbox("Unsigned", unsignedModulation);
        widget.tooltip("Show 0.5 p + 0.5 in [0, 1] instead of the zero-mean pattern p in [-1, 1].", true);

        if (pattern == ProjectorPatternType::Periodic)
        {
            dirty |= renderWaveformUI(widget, waveform);
            dirty |= widget.var("Wavelength (uv)", patternWavelength, 1e-4f, 1.f);
            widget.tooltip("Period of the pattern, in uv units.", true);
            dirty |= widget.var("Phase", patternPhase, -1.f, 1.f);
            widget.tooltip("Pattern offset, in periods.", true);
        }
        else if (pattern == ProjectorPatternType::Gray || pattern == ProjectorPatternType::XOR)
        {
            dirty |= widget.var("Bits", patternBits, 1u, 24u);
            widget.tooltip("The pattern has 2^bits columns.", true);
            dirty |= widget.var("Bit", patternBit, 0u, 24u);
            widget.tooltip("Bit of the code shown, 0 = finest stripes.", true);
            if (pattern == ProjectorPatternType::XOR)
            {
                dirty |= widget.var("Base bit", patternBaseBit, 0u, 24u);
                widget.tooltip("Bit XORed with the higher bits: 0 = XOR-02, 1 = XOR-04, ...", true);
            }
        }
        else if (pattern == ProjectorPatternType::Checkerboard)
        {
            dirty |= widget.var("Cells", checkerCells, 1u, 4096u);
            widget.tooltip("Checker cells along u and v.", true);
            dirty |= widget.var("Shift", checkerShift, 0u, 24u);
            widget.tooltip("Sub-cell shift: (shift mod 5, shift / 5) fifths of a cell along u and v.", true);
        }
        return dirty;
    }
};

/// Data of the arbitrary pattern: one 0 / 1 value per column, and its antithetic map, either a column matching or
/// intervals mapped linearly onto intervals. The textures are created on first use.
class ProjectorPatternData
{
public:
    /// `values`: 0 or 1 per column. `antitheticIndex`: the column matched to each column. `intervalIds`: the interval
    /// of each column; `intervals`: (srcStart, srcEnd, dstStart, dstEnd) per interval, in columns. Give either the
    /// matching or the intervals, or neither (no antithetic partner). Warns when the map is not its own inverse or
    /// does not flip the value, which makes antithetic sampling biased or ineffective.
    void set(std::vector<uint32_t> values, std::vector<uint32_t> antitheticIndex, std::vector<uint32_t> intervalIds,
        std::vector<uint32_t> intervals)
    {
        const size_t width = values.size();
        if (width == 0)
            FALCOR_THROW("The pattern needs at least one column.");
        if (!antitheticIndex.empty() && !intervalIds.empty())
            FALCOR_THROW("Give either antithetic_index or interval_ids and intervals, not both.");
        if (!antitheticIndex.empty() && antitheticIndex.size() != width)
            FALCOR_THROW("antithetic_index must have one entry per column.");
        if (!intervalIds.empty() && (intervalIds.size() != width || intervals.empty() || intervals.size() % 4 != 0))
            FALCOR_THROW("interval_ids must have one entry per column and intervals four entries per interval.");

        for (size_t column = 0; column < antitheticIndex.size(); column++)
        {
            const uint32_t partner = antitheticIndex[column];
            if (partner >= width)
                FALCOR_THROW("antithetic_index[{}] = {} is out of range.", column, partner);
            if (antitheticIndex[partner] != column || values[partner] == values[column])
            {
                logWarning("antithetic_index is not a matching of opposite values (at column {}).", column);
                break;
            }
        }
        const size_t intervalCount = intervals.size() / 4;
        for (size_t column = 0; column < intervalIds.size(); column++)
            if (intervalIds[column] >= intervalCount)
                FALCOR_THROW("interval_ids[{}] = {} is out of range.", column, intervalIds[column]);
        for (size_t interval = 0; interval < intervalCount; interval++)
        {
            const uint32_t* entry = &intervals[4 * interval];
            // The interval that the destination starts in must map back onto this interval.
            const uint32_t back = entry[2] < width ? intervalIds[entry[2]] : uint32_t(intervalCount);
            if (back >= intervalCount || intervals[4 * back] != entry[2] || intervals[4 * back + 1] != entry[3] ||
                intervals[4 * back + 2] != entry[0] || intervals[4 * back + 3] != entry[1])
            {
                logWarning("intervals are not mapped back onto themselves (interval {}).", interval);
                break;
            }
        }

        mValues = std::move(values);
        mAntitheticIndex = std::move(antitheticIndex);
        mIntervalIds = std::move(intervalIds);
        mIntervals = std::move(intervals);
        mpValues = mpAntitheticIndex = mpIntervalIds = mpIntervals = nullptr;
    }

    bool empty() const { return mValues.empty(); }

    /// Binds the textures and sets gArbitraryWidth and gArbitraryMapping.
    void bindShaderData(ref<Device> pDevice, const ShaderVar& var)
    {
        if (empty())
            FALCOR_THROW("The arbitrary pattern needs set_pattern_data().");
        auto create = [&](ref<Texture>& pTexture, const std::vector<uint32_t>& data)
        {
            if (!pTexture && !data.empty())
                pTexture = pDevice->createTexture1D((uint32_t)data.size(), ResourceFormat::R32Uint, 1, 1, data.data());
        };
        create(mpValues, mValues);
        create(mpAntitheticIndex, mAntitheticIndex);
        create(mpIntervalIds, mIntervalIds);
        create(mpIntervals, mIntervals);
        var["gPatternValues"] = mpValues;
        var["gAntitheticIndex"] = mpAntitheticIndex;
        var["gIntervalIds"] = mpIntervalIds;
        var["gIntervals"] = mpIntervals;
        var["ProjectorPatternCB"]["gArbitraryWidth"] = (uint32_t)mValues.size();
        var["ProjectorPatternCB"]["gArbitraryMapping"] = !mAntitheticIndex.empty() ? 1u : !mIntervalIds.empty() ? 2u : 0u;
    }

private:
    std::vector<uint32_t> mValues;
    std::vector<uint32_t> mAntitheticIndex;
    std::vector<uint32_t> mIntervalIds;
    std::vector<uint32_t> mIntervals;
    ref<Texture> mpValues;
    ref<Texture> mpAntitheticIndex;
    ref<Texture> mpIntervalIds;
    ref<Texture> mpIntervals;
};
