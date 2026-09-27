#include "LaserLight.h"
#include "../Shared/Host/InlinePassUtils.h"
#include <algorithm>
#include <cmath>

static void regLaserLight(pybind11::module& m)
{
    pybind11::class_<LaserLight, RenderPass, ref<LaserLight>> pass(m, "LaserLight");
    pass.def("update_laser_info", &LaserLight::updateLaserInfo);
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
    return props;
}

void LaserLight::setProperties(const Properties& props)
{
    parseProperties(props);
    mOptionsChanged = true;
}

void LaserLight::updateLaserInfo(const float3& position, const float3& direction)
{
    mLaser.origin = position;
    mLaser.direction = normalizeDirection(direction);
}

void LaserLight::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }

    LaserState laser = mLaser;
    if (mLaser.collocated && mpScene)
    {
        const auto& pCamera = mpScene->getCamera();
        laser.origin = pCamera->getPosition();
        laser.direction = normalize(pCamera->getTarget() - pCamera->getPosition());
    }
    laser.publish(renderData);

    mLaser.origin += mVelocity;
}

void LaserLight::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.checkbox("Laser source", mLaser.isLaser);
    widget.tooltip("On: the light is the spot where the laser beam hits the scene, and the beam length adds to the "
                   "path length.\nOff: a point light at the laser position.", true);

    dirty |= widget.checkbox("Laser collocated", mLaser.collocated);
    widget.tooltip("Place the laser at the camera, aimed at the camera target, instead of at laserPosition and "
                   "laserDirection. The laser follows the camera when it moves.", true);

    if (!mLaser.collocated)
    {
        dirty |= widget.var("laserPosition", mLaser.origin, -FLT_MAX, FLT_MAX, 0.001f, false, "%.4f");
        float3 direction = mLaser.direction;
        if (widget.var("laserDirection", direction, -1.f, 1.f, 0.001f, false, "%.4f") && length(direction) > 0.f)
        {
            mLaser.direction = normalize(direction);
            dirty = true;
        }
    }

    dirty |= widget.var("laserPower", mLaser.power, 0.f, FLT_MAX, 0.001f, false, "%.4f");
    widget.tooltip("Power of the laser (or intensity of the point light), per color channel.", true);

    float angle = angleDegrees(mLaser.cosAngle);
    if (widget.var("laserAngle", angle, 0.f, 90.f, 0.1f, false, "%.2f"))
    {
        mLaser.cosAngle = cosAngleDegrees(angle);
        dirty = true;
    }
    widget.tooltip("Half-angle of the laser cone in degrees. 0 = collimated beam.", true);

    // Downstream passes restart their accumulation when the light changes.
    if (dirty)
        mOptionsChanged = true;
}
