#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "Configs/ProjectorConfig.h"
#include <memory>

using namespace Falcor;

/** The point light as a projector (LaserLight's "projector"): a pinhole along the light's direction whose image, over the
 * field of view, shows a pattern of Shared/Shaders/Projector/ProjectorPatterns.slang. The light's intensity toward the
 * image-plane point uv is laserPower * pattern(uv) / cos^3, with cos the cosine to the light's direction, so that the
 * image-plane irradiance is uniform, as for ProjectorLight; it is zero outside the field of view. The laser beam
 * ignores it.
 */
struct LaserProjector
{
    static constexpr char kEnabled[] = "enabled";
    static constexpr char kFov[] = "fov";
    static constexpr char kUp[] = "up";

    bool enabled = false;
    /// Full field of view along u and v, in degrees; (0, 0): the camera's (LaserLight resolves it every frame).
    float2 fov = float2(0.f);
    /// Up hint, made orthogonal to the light's direction: v runs along it. The camera's up when the light is collocated.
    float3 up = float3(0.f, 1.f, 0.f);
    ProjectorPatternConfig pattern = defaultPattern();
    /// The arbitrary pattern (LaserLight.set_pattern_data), with its textures.
    std::shared_ptr<ProjectorPatternData> patternData;

    /// A constant, unsigned pattern: the projector shows values in [0, 1], white by default.
    static ProjectorPatternConfig defaultPattern()
    {
        ProjectorPatternConfig pattern;
        pattern.type = ProjectorPatternType::Constant;
        pattern.unsignedModulation = true;
        return pattern;
    }

    bool operator==(const LaserProjector& other) const
    {
        return enabled == other.enabled && all(fov == other.fov) && all(up == other.up) && pattern == other.pattern &&
               patternData == other.patternData;
    }
    bool operator!=(const LaserProjector& other) const { return !(*this == other); }

    void validate() const
    {
        const bool cameraFov = fov.x == 0.f && fov.y == 0.f;
        if (!cameraFov && !(fov.x > 0.f && fov.x < 180.f && fov.y > 0.f && fov.y < 180.f))
            FALCOR_THROW("The projector's fov must be in (0, 180) degrees, or (0, 0) for the camera's.");
        if (!(length(up) > 0.f) || !std::isfinite(up.x + up.y + up.z))
            FALCOR_THROW("The projector's up must be a nonzero, finite vector.");
        pattern.validate();
    }

    /// Merges LaserLight's "projector" dictionary: enabled (true when not given), fov, up and the pattern keys of
    /// ProjectorPatternConfig. Throws on an unknown key.
    void parse(const Properties& props)
    {
        enabled = true;
        for (const auto& [key, value] : props)
        {
            if (key == kEnabled)
                enabled = value;
            else if (key == kFov)
                fov = value;
            else if (key == kUp)
                up = value;
            else if (!pattern.parse(key, value))
                FALCOR_THROW("Unknown key '{}' in LaserLight's projector.", key);
        }
        validate();
    }

    Properties serialize() const
    {
        Properties props;
        props[kEnabled] = enabled;
        props[kFov] = fov;
        props[kUp] = up;
        pattern.serialize(props);
        return props;
    }

    /// PROJECTOR_PATTERN of the pattern shown (constant without the projector).
    DefineList getDefines() const { return enabled ? pattern.getDefines() : defaultPattern().getDefines(); }
};

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
    static constexpr char kPatternPhaseShift[] = "patternPhaseShift";
    static constexpr char kProjector[] = "laserProjector";
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
    /// Added to patternPhase in each color channel: e.g. (0, 2 pi / 3, 4 pi / 3) renders three phase-shifted fringes
    /// on the same paths, so that their demodulation cancels the uniform light path by path.
    float3 patternPhaseShift = float3(0.f);
    /// The point light as a projector (LaserProjector), its field of view and up resolved by LaserLight.
    LaserProjector projector;

    bool operator==(const LaserState& other) const
    {
        return all(origin == other.origin) && all(direction == other.direction) && all(power == other.power) &&
               cosAngle == other.cosAngle && isLaser == other.isLaser && collocated == other.collocated &&
               all(patternFrequency == other.patternFrequency) && patternPhase == other.patternPhase &&
               all(patternPhaseShift == other.patternPhaseShift) && projector == other.projector;
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
        dict[kPatternPhaseShift] = patternPhaseShift;
        dict[kProjector] = projector;
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
        laser.patternPhaseShift = dict.getValue(kPatternPhaseShift, laser.patternPhaseShift);
        laser.projector = dict.getValue(kProjector, laser.projector);
        return laser;
    }

    /// IS_LIGHT_SOURCE_LASER and the projector's PROJECTOR_PATTERN.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("IS_LIGHT_SOURCE_LASER", isLaser ? "1" : "0");
        defines.add(projector.getDefines());
        return defines;
    }

    /// Whether the light is the point light as a projector.
    bool isProjector() const { return projector.enabled && !isLaser; }

    /// Sets the Laser constants (Shared/Shaders/Lights/Laser.slang) under the program's root `var`.
    void bindShaderData(const ShaderVar& var) const
    {
        auto laserVar = var["Laser"];
        laserVar["gLaserOrigin"] = origin;
        laserVar["gLaserDirection"] = direction;
        laserVar["gLaserPower"] = power;
        laserVar["gLaserCosAngle"] = cosAngle;
        laserVar["gLaserPatternFrequency"] = patternFrequency;
        laserVar["gLaserPatternPhase"] = patternPhase + patternPhaseShift;

        // The projector (LaserProjector in LaserLightSampler.slang, ProjectorPatternCB in ProjectorPatterns.slang), in
        // the programs that import them.
        if (auto projectorVar = var.findMember("LaserProjector"); projectorVar.isValid())
        {
            projectorVar["gLaserProjector"] = uint(isProjector());
            if (isProjector())
            {
                const float3 forward = normalize(direction);
                const float3 right = normalize(cross(forward, projector.up));
                projectorVar["gLaserProjectorRight"] = right;
                projectorVar["gLaserProjectorUp"] = cross(right, forward);
                projectorVar["gLaserProjectorTanHalfFov"] =
                    float2(std::tan(math::radians(0.5f * projector.fov.x)), std::tan(math::radians(0.5f * projector.fov.y)));
            }
        }
        if (auto patternVar = var.findMember("ProjectorPatternCB"); patternVar.isValid() && isProjector())
        {
            projector.pattern.bindShaderData(patternVar);
            if (projector.pattern.type == ProjectorPatternType::Arbitrary && projector.patternData)
                projector.patternData->bindShaderData(var);
        }
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
