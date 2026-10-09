#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "RenderGraph/RenderPassStandardFlags.h"

using namespace Falcor;

/** The laser for one frame. The LaserLight pass publishes it in the render data dictionary (publish()), and the
 * passes that use the laser read it back through a LaserInput, so they all see the same laser, including when it is
 * collocated with the camera. Those passes need an execution edge from LaserLight (graph.add_edge("Laser",
 * "Tracer")) so that it runs first.
 */
struct LaserState
{
    static constexpr char kOrigin[] = "laserPosition";
    static constexpr char kDirection[] = "laserDirection";
    static constexpr char kPower[] = "laserPower";
    static constexpr char kCosAngle[] = "laserCosAngle";
    static constexpr char kIsLaser[] = "isLightSourceLaser";
    static constexpr char kCollocated[] = "laserCollocated";
    static constexpr char kPatternFrequency[] = "patternFrequency";
    static constexpr char kPatternPhase[] = "patternPhase";
    static constexpr char kToken[] = "laserToken"; ///< Changes at every publication (LaserInput).

    float3 origin = float3(0.f);
    float3 direction = float3(0.f, 0.f, 1.f);
    float3 power = float3(1.f);
    float cosAngle = 1.f; ///< Cosine of the cone half-angle: 1 is a collimated beam.
    /// The light is the spot the beam hits; otherwise a point light at the origin, which lights the half-space in front
    /// of `direction` (cosAngle does not apply to it).
    bool isLaser = true;
    bool collocated = false; ///< The laser is at the camera, aimed at its target.
    /// The point light as a projector of sinusoidal fringes: its intensity in the unit direction d is scaled by
    /// (1 + cos(2 pi patternFrequency . d / (d . direction) + patternPhase)) / 2, a sinusoid of patternFrequency
    /// (cycles per meter) on the plane 1 m in front of the light, normal to `direction`. Zero (and phase 0): no pattern.
    float3 patternFrequency = float3(0.f);
    float patternPhase = 0.f; ///< Radians.

    bool operator==(const LaserState& other) const
    {
        return all(origin == other.origin) && all(direction == other.direction) && all(power == other.power) &&
               cosAngle == other.cosAngle && isLaser == other.isLaser && collocated == other.collocated &&
               all(patternFrequency == other.patternFrequency) && patternPhase == other.patternPhase;
    }
    bool operator!=(const LaserState& other) const { return !(*this == other); }

    /// Stores the laser in the render data dictionary for the passes that run after the laser pass, with a token that
    /// differs from every earlier one (0 is never used).
    void publish(const RenderData& renderData, uint32_t token) const
    {
        auto& dict = renderData.getDictionary();
        dict[kToken] = token;
        dict[kOrigin] = origin;
        dict[kDirection] = direction;
        dict[kPower] = power;
        dict[kCosAngle] = cosAngle;
        dict[kIsLaser] = isLaser;
        dict[kCollocated] = collocated;
        dict[kPatternFrequency] = patternFrequency;
        dict[kPatternPhase] = patternPhase;
    }

    /// The laser last published in the dictionary; the defaults where none was. Passes use LaserInput instead.
    static LaserState read(const RenderData& renderData)
    {
        auto& dict = renderData.getDictionary();
        LaserState laser;
        laser.origin = dict.getValue(kOrigin, laser.origin);
        laser.direction = dict.getValue(kDirection, laser.direction);
        laser.power = dict.getValue(kPower, laser.power);
        laser.cosAngle = dict.getValue(kCosAngle, laser.cosAngle);
        laser.isLaser = dict.getValue(kIsLaser, laser.isLaser);
        laser.collocated = dict.getValue(kCollocated, laser.collocated);
        laser.patternFrequency = dict.getValue(kPatternFrequency, laser.patternFrequency);
        laser.patternPhase = dict.getValue(kPatternPhase, laser.patternPhase);
        return laser;
    }

    /// IS_LIGHT_SOURCE_LASER.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("IS_LIGHT_SOURCE_LASER", isLaser ? "1" : "0");
        return defines;
    }

    /// Sets the Laser constants (Shared/Shaders/Lights/Laser.slang) under `var`.
    void bindShaderData(const ShaderVar& var) const
    {
        var["gLaserOrigin"] = origin;
        var["gLaserDirection"] = direction;
        var["gLaserPower"] = power;
        var["gLaserCosAngle"] = cosAngle;
        var["gLaserPatternFrequency"] = patternFrequency;
        var["gLaserPatternPhase"] = patternPhase;
    }
};

/** A pass's laser: what the LaserLight pass published this frame (update(), once per frame at the start of execute),
 * or the default laser, with a warning, when no laser pass ran since the pass's previous frame (none in the graph, a
 * removed one, or no execution edge to this pass). The dictionary keeps the last publication, so a removed laser pass
 * would otherwise go unnoticed.
 */
class LaserInput
{
public:
    const LaserState& update(const RenderData& renderData, const char* passName)
    {
        const uint32_t token = renderData.getDictionary().getValue(LaserState::kToken, 0u);
        if (token != 0 && token != mToken)
        {
            mLaser = LaserState::read(renderData);
            mToken = token;
            mMissing = false;
        }
        else if (!mMissing)
        {
            logWarning("{}: no laser was published this frame. Add a LaserLight pass with an execution edge to this "
                       "pass, e.g. graph.add_edge(\"Laser\", \"Tracer\"). Using the default laser.", passName);
            mLaser = LaserState();
            mMissing = true;
            // The light changed: downstream accumulation restarts, as when LaserLight changes it.
            auto& dict = renderData.getDictionary();
            const auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
            dict[kRenderPassRefreshFlags] = flags | RenderPassRefreshFlags::RenderOptionsChanged;
        }
        return mLaser;
    }

    /// The laser of the last update().
    const LaserState& get() const { return mLaser; }

private:
    LaserState mLaser;
    uint32_t mToken = 0;
    bool mMissing = false;
};
