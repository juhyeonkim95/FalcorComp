#include "LaserLight.h"
#include "../Shared/Host/InlinePassUtils.h"
#include <algorithm>
#include <atomic>
#include <cmath>

static void regLaserLight(pybind11::module& m)
{
    using namespace pybind11::literals;
    pybind11::class_<LaserLight, RenderPass, ref<LaserLight>> pass(m, "LaserLight");
    pass.def("update_laser_info", &LaserLight::updateLaserInfo);
    pass.def("set_pattern_data", &LaserLight::setPatternData, "values"_a);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, LaserLight>();
    ScriptBindings::registerBinding(regLaserLight);
}

namespace
{
const char kLaserPosition[] = "laserPosition";
const char kLaserDirection[] = "laserDirection";
const char kLaserPower[] = "laserPower";
const char kLaserAngle[] = "laserAngle";
const char kLaserVelocity[] = "laserVelocity";
const char kLaserCollocated[] = "laserCollocated";
const char kIsLightSourceLaser[] = "isLightSourceLaser";
const char kPatternFrequency[] = "patternFrequency";
const char kPatternPhase[] = "patternPhase";
const char kPatternPhaseShift[] = "patternPhaseShift";
const char kProjector[] = "projector";

float3 normalizeDirection(const float3& direction)
{
    const float norm = length(direction);
    if (!(norm > 0.f) || !std::isfinite(norm))
        FALCOR_THROW("laserDirection must be a nonzero, finite vector.");
    return direction / norm;
}

float cosAngleDegrees(float degrees)
{
    return float(std::cos(double(degrees) * M_PI / 180.0));
}

float angleDegrees(float cosAngle)
{
    return float(std::acos(std::clamp(cosAngle, -1.f, 1.f)) * 180.0 / M_PI);
}
} // namespace

LaserLight::LaserLight(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    mPosition = mLaser.origin;
}

void LaserLight::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kLaserPosition)
            mLaser.origin = value;
        else if (key == kLaserDirection)
            mLaser.direction = normalizeDirection(value);
        else if (key == kLaserPower)
            mLaser.power = value;
        else if (key == kLaserAngle)
            mLaser.cosAngle = cosAngleDegrees(value);
        else if (key == kLaserVelocity)
            mVelocity = value;
        else if (key == kLaserCollocated)
            mLaser.collocated = value;
        else if (key == kIsLightSourceLaser)
            mLaser.isLaser = value;
        else if (key == kPatternFrequency)
            mLaser.patternFrequency = value;
        else if (key == kPatternPhase)
            mLaser.patternPhase = value;
        else if (key == kPatternPhaseShift)
            mLaser.patternPhaseShift = value;
        else if (key == kProjector)
        {
            const Properties projector = value;
            mLaser.projector.parse(projector);
        }
        else
            logWarning("Unknown property '{}' in LaserLight properties.", key);
    }
}

Properties LaserLight::getProperties() const
{
    Properties props;
    props[kLaserPosition] = mLaser.origin;
    props[kLaserDirection] = mLaser.direction;
    props[kLaserPower] = mLaser.power;
    props[kLaserAngle] = angleDegrees(mLaser.cosAngle);
    props[kLaserVelocity] = mVelocity;
    props[kLaserCollocated] = mLaser.collocated;
    props[kIsLightSourceLaser] = mLaser.isLaser;
    props[kPatternFrequency] = mLaser.patternFrequency;
    props[kPatternPhase] = mLaser.patternPhase;
    props[kPatternPhaseShift] = mLaser.patternPhaseShift;
    if (mLaser.projector != LaserProjector())
        props[kProjector] = mLaser.projector.serialize();
    return props;
}

void LaserLight::setProperties(const Properties& props)
{
    // An invalid property (e.g. a zero direction) throws and leaves the light unchanged.
    const LaserState laser = mLaser;
    const float3 velocity = mVelocity;
    try
    {
        parseProperties(props);
    }
    catch (...)
    {
        mLaser = laser;
        mVelocity = velocity;
        throw;
    }
    mPosition = mLaser.origin; // The motion restarts from laserPosition.
    mOptionsChanged = true;
}

void LaserLight::setPatternData(std::vector<uint32_t> values)
{
    auto pData = std::make_shared<ProjectorPatternData>();
    pData->set(std::move(values), {}, {}, {});
    pData->createTextures(mpDevice);
    mLaser.projector.patternData = std::move(pData);
    mOptionsChanged = true;
}

void LaserLight::updateLaserInfo(const float3& position, const float3& direction)
{
    mLaser.direction = normalizeDirection(direction);
    mLaser.origin = position;
    mPosition = position;
}

void LaserLight::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    LaserState laser = mLaser;
    laser.origin = mPosition;
    if (mLaser.collocated && mpScene)
    {
        const auto& pCamera = mpScene->getCamera();
        laser.origin = pCamera->getPosition();
        laser.direction = normalize(pCamera->getTarget() - pCamera->getPosition());
        laser.projector.up = pCamera->getUpVector();
    }
    if (laser.isProjector())
    {
        // (0, 0): the camera's field of view.
        if (all(laser.projector.fov == float2(0.f)) && mpScene)
        {
            const auto& pCamera = mpScene->getCamera();
            const float halfHeight = 0.5f * pCamera->getFrameHeight() / pCamera->getFocalLength();
            laser.projector.fov = 2.f * float2(std::atan(halfHeight * pCamera->getAspectRatio()), std::atan(halfHeight)) *
                                  float(180.0 / M_PI);
        }
        if (!(length(cross(laser.direction, laser.projector.up)) > 0.f))
            FALCOR_THROW("LaserLight: the projector's up is parallel to the light's direction.");
        if (laser.projector.pattern.type == ProjectorPatternType::Arbitrary && !laser.projector.patternData)
            FALCOR_THROW("LaserLight: the projector's arbitrary pattern needs set_pattern_data().");
    }
    // Shared by all LaserLight passes, so that a replacement pass never repeats a token the users have seen.
    static std::atomic<uint32_t> sToken{0};
    uint32_t token = ++sToken;
    if (token == 0)
        token = ++sToken;
    laser.publish(renderData, token);

    // Downstream accumulation restarts when the light changes: a UI edit, properties, update_laser_info,
    // laserVelocity, or a collocated laser following the camera.
    if (mOptionsChanged || laser != mPublished)
        InlinePass::flagOptionsChanged(renderData);
    mOptionsChanged = false;
    mPublished = laser;

    mPosition += mVelocity;
}

void LaserLight::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.checkbox("Laser source", mLaser.isLaser);
    widget.tooltip("On: the light is the spot where the laser beam hits the scene, and the beam length adds to the "
                   "path length.\nOff: a point light at the laser position, lighting the half-space in front of "
                   "laserDirection.", true);

    dirty |= widget.checkbox("Laser collocated", mLaser.collocated);
    widget.tooltip("Place the laser at the camera, aimed at the camera target, instead of at laserPosition and "
                   "laserDirection. The laser follows the camera when it moves.", true);

    if (!mLaser.collocated)
    {
        if (widget.var("laserPosition", mLaser.origin, -FLT_MAX, FLT_MAX, 0.001f, false, "%.4f"))
        {
            mPosition = mLaser.origin; // The motion restarts from the new position.
            dirty = true;
        }
        if (any(mVelocity != float3(0.f)))
        {
            widget.text(fmt::format("Moving with laserVelocity, now at ({:.4f}, {:.4f}, {:.4f})", mPosition.x,
                mPosition.y, mPosition.z));
        }
        float3 direction = mLaser.direction;
        if (widget.var("laserDirection", direction, -1.f, 1.f, 0.001f, false, "%.4f") && length(direction) > 0.f)
        {
            mLaser.direction = normalize(direction);
            dirty = true;
        }
    }

    dirty |= widget.var("laserPower", mLaser.power, 0.f, FLT_MAX, 0.001f, false, "%.4f");
    widget.tooltip("Power of the laser (or intensity of the point light), per color channel.", true);

    if (mLaser.isLaser) // A point light has no cone.
    {
        float angle = angleDegrees(mLaser.cosAngle);
        if (widget.var("laserAngle", angle, 0.f, 90.f, 0.1f, false, "%.2f"))
        {
            mLaser.cosAngle = cosAngleDegrees(angle);
            dirty = true;
        }
        widget.tooltip("Half-angle of the laser cone in degrees. 0 = collimated beam.", true);
    }
    else
    {
        dirty |= widget.var("patternFrequency", mLaser.patternFrequency, -FLT_MAX, FLT_MAX, 0.01f, false, "%.3f");
        widget.tooltip("Sinusoidal fringes of the point light, as a projector: cycles per meter on the plane 1 m in "
                       "front of the light, normal to its direction. Zero: none.", true);
        dirty |= widget.var("patternPhase", mLaser.patternPhase, -FLT_MAX, FLT_MAX, 0.01f, false, "%.3f");
        widget.tooltip("Phase of the fringes, radians.", true);
        dirty |= widget.var("patternPhaseShift", mLaser.patternPhaseShift, -FLT_MAX, FLT_MAX, 0.01f, false, "%.3f");
        widget.tooltip("Added to the phase in each color channel, e.g. (0, 2.094, 4.189): three phase-shifted fringes "
                       "rendered on the same paths.", true);

        LaserProjector& projector = mLaser.projector;
        dirty |= widget.checkbox("Projector", projector.enabled);
        widget.tooltip("A pinhole projector along laserDirection: the light's intensity toward the image-plane point "
                       "uv is laserPower * pattern(uv) / cos^3, and zero outside the field of view.", true);
        if (projector.enabled)
        {
            if (auto group = widget.group("Projector", true))
            {
                float2 fov = projector.fov;
                if (group.var("Field of view (deg)", fov, 0.f, 179.f))
                {
                    projector.fov = fov;
                    dirty = true;
                }
                group.tooltip("Full field of view along u and v, in degrees; (0, 0): the camera's.", true);
                if (!mLaser.collocated)
                {
                    float3 up = projector.up;
                    if (group.var("Up", up, -1.f, 1.f) && length(up) > 0.f)
                    {
                        projector.up = up;
                        dirty = true;
                    }
                    group.tooltip("Up hint: v runs along it, made orthogonal to laserDirection.", true);
                }
                dirty |= projector.pattern.renderUI(group);
            }
        }
    }

    // Downstream passes restart their accumulation when the light changes.
    if (dirty)
        mOptionsChanged = true;
}
