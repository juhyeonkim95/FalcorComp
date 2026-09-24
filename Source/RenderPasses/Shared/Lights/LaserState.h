#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"

using namespace Falcor;

/** The laser for one frame. LaserVBufferRT publishes it in the render data dictionary (publish()), and the passes
 * that use the laser read it back (resolve()), so they all see the same laser, including when it is collocated
 * with the camera.
 */
struct LaserState
{
    static constexpr char kOrigin[] = "laserPosition";
    static constexpr char kDirection[] = "laserDirection";
    static constexpr char kPower[] = "laserPower";
    static constexpr char kCosAngle[] = "laserCosAngle";
    static constexpr char kIsLaser[] = "isLightSourceLaser";

    float3 origin = float3(0.f);
    float3 direction = float3(0.f, 0.f, 1.f);
    float3 power = float3(1.f);
    float cosAngle = 0.f; ///< Cosine of the cone half-angle.
    bool isLaser = true;  ///< The light is the spot the beam hits; otherwise a point light at the origin.

    bool operator==(const LaserState& other) const
    {
        return all(origin == other.origin) && all(direction == other.direction) && all(power == other.power) &&
               cosAngle == other.cosAngle && isLaser == other.isLaser;
    }
    bool operator!=(const LaserState& other) const { return !(*this == other); }

    /// Stores the laser in the render data dictionary for the passes that run after the laser pass.
    void publish(const RenderData& renderData) const
    {
        auto& dict = renderData.getDictionary();
        dict[kOrigin] = origin;
        dict[kDirection] = direction;
        dict[kPower] = power;
        dict[kCosAngle] = cosAngle;
        dict[kIsLaser] = isLaser;
    }

    /// The laser the laser pass published this frame; the defaults where it did not.
    static LaserState resolve(const RenderData& renderData)
    {
        auto& dict = renderData.getDictionary();
        LaserState laser;
        laser.origin = dict.getValue(kOrigin, laser.origin);
        laser.direction = dict.getValue(kDirection, laser.direction);
        laser.power = dict.getValue(kPower, laser.power);
        laser.cosAngle = dict.getValue(kCosAngle, laser.cosAngle);
        laser.isLaser = dict.getValue(kIsLaser, laser.isLaser);
        return laser;
    }

    /// IS_LIGHT_SOURCE_LASER.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("IS_LIGHT_SOURCE_LASER", isLaser ? "1" : "0");
        return defines;
    }

    /// Sets laserOrigin, laserDirection, laserPower and laserCosAngle under `var`.
    void bindShaderData(const ShaderVar& var) const
    {
        var["laserOrigin"] = origin;
        var["laserDirection"] = direction;
        var["laserPower"] = power;
        var["laserCosAngle"] = cosAngle;
    }
};
