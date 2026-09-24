#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/Scene.h"

/// The laser for one frame.
struct LaserState
{
    float3 origin = float3(0.f);
    float3 direction = float3(0.f, 0.f, 1.f);
    float3 power = float3(1.f);
    float cosAngle = 0.f; ///< Cosine of the cone half-angle.

    bool operator==(const LaserState& other) const
    {
        return all(origin == other.origin) && all(direction == other.direction) && all(power == other.power) &&
               cosAngle == other.cosAngle;
    }
    bool operator!=(const LaserState& other) const { return !(*this == other); }

    /// The laser for this frame: at the camera, aimed at its target, when `collocated`; otherwise from the laser
    /// pass (LaserVBufferRT) through the render data dictionary.
    static LaserState resolve(const RenderData& renderData, const Scene& scene, bool collocated)
    {
        auto& dict = renderData.getDictionary();
        LaserState laser;
        if (collocated)
        {
            const auto& pCamera = scene.getCamera();
            laser.origin = pCamera->getPosition();
            laser.direction = normalize(pCamera->getTarget() - pCamera->getPosition());
        }
        else
        {
            laser.origin = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0.f);
            laser.direction = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0.f, 0.f, 1.f);
        }
        laser.power = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1.f);
        laser.cosAngle = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.f;
        return laser;
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

/// Camera paths, the light and the output.
struct PathTracingConfig
{
    uint samplesPerPixel = 128;
    uint maxBounces = 3; ///< Maximum surface vertices on a camera path, counting the primary hit.
    bool computeDirect = false; ///< Include camera -> primary hit -> laser spot.
    bool useImportanceSampling = true;
    bool useAlphaTest = false;
    bool useSingleChannel = false;
    bool isLightSourceLaser = true; ///< Laser spot as the light; otherwise a point light at the laser position.
    bool laserCollocated = false;   ///< Place the laser at the camera.

    void validate() const
    {
        if (samplesPerPixel == 0)
            FALCOR_THROW("samplesPerPixel must be greater than zero.");
    }

    /// MAX_BOUNCES, COMPUTE_DIRECT, USE_IMPORTANCE_SAMPLING, USE_ALPHA_TEST, USE_SINGLE_CHANNEL, IS_LIGHT_SOURCE_LASER.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("MAX_BOUNCES", std::to_string(maxBounces));
        defines.add("COMPUTE_DIRECT", computeDirect ? "1" : "0");
        defines.add("USE_IMPORTANCE_SAMPLING", useImportanceSampling ? "1" : "0");
        defines.add("USE_ALPHA_TEST", useAlphaTest ? "1" : "0");
        defines.add("USE_SINGLE_CHANNEL", useSingleChannel ? "1" : "0");
        defines.add("IS_LIGHT_SOURCE_LASER", isLightSourceLaser ? "1" : "0");
        return defines;
    }

    /// This frame's laser (see LaserState::resolve()).
    LaserState resolveLaser(const RenderData& renderData, const Scene& scene) const
    {
        return LaserState::resolve(renderData, scene, laserCollocated);
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "samplesPerPixel")
            samplesPerPixel = value;
        else if (key == "maxBounces")
            maxBounces = value;
        else if (key == "computeDirect")
            computeDirect = value;
        else if (key == "useImportanceSampling")
            useImportanceSampling = value;
        else if (key == "useAlphaTest")
            useAlphaTest = value;
        else if (key == "useSingleChannel")
            useSingleChannel = value;
        else if (key == "isLightSourceLaser")
            isLightSourceLaser = value;
        else if (key == "laserCollocated")
            laserCollocated = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["samplesPerPixel"] = samplesPerPixel;
        props["maxBounces"] = maxBounces;
        props["computeDirect"] = computeDirect;
        props["useImportanceSampling"] = useImportanceSampling;
        props["useAlphaTest"] = useAlphaTest;
        props["useSingleChannel"] = useSingleChannel;
        props["isLightSourceLaser"] = isLightSourceLaser;
        props["laserCollocated"] = laserCollocated;
    }

    /// Samples per pixel, max bounces and BSDF importance sampling. `maxBouncesNote` is appended to its tooltip.
    bool renderSamplingUI(Gui::Widgets& widget, const std::string& maxBouncesNote = "")
    {
        bool dirty = false;
        dirty |= widget.var("Samples per pixel", samplesPerPixel, 1u, 1024u);
        widget.tooltip("Camera paths traced per pixel in each frame.", true);

        dirty |= widget.var("Max bounces", maxBounces, 0u, 1u << 16);
        widget.tooltip("Maximum number of surface vertices on the camera path, counting the primary hit and any "
                       "vertex inserted by an ellipsoidal connection." + maxBouncesNote, true);

        dirty |= widget.checkbox("Use importance sampling", useImportanceSampling);
        widget.tooltip("Importance-sample the BSDF when extending the camera path. Off: the material's reference "
                       "sampler (cosine-weighted for standard materials).", true);
        return dirty;
    }

    /// Laser source and placement.
    bool renderLightUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        dirty |= widget.checkbox("Laser source", isLightSourceLaser);
        widget.tooltip("On: the light is the spot where the laser beam hits the scene, and the beam length adds to "
                       "the path length.\nOff: a point light at the laser position.", true);

        dirty |= widget.checkbox("Laser collocated", laserCollocated);
        widget.tooltip("Place the laser at the camera, aimed at the camera target, instead of using the laser pass "
                       "position and direction. The laser follows the camera when it moves.", true);
        return dirty;
    }

    /// Output options. `pathTracerOptions` also shows computeDirect and useSingleChannel, which only the
    /// path tracer implements.
    bool renderOutputUI(Gui::Widgets& widget, bool pathTracerOptions)
    {
        bool dirty = false;
        if (pathTracerOptions)
        {
            dirty |= widget.checkbox("Primary-hit direct", computeDirect);
            widget.tooltip("Include the shortest path, camera -> primary hit -> laser spot (time gated).", true);

            dirty |= widget.checkbox("Single channel", useSingleChannel);
            widget.tooltip("Copy the red channel to green and blue.", true);
        }
        dirty |= widget.checkbox("Alpha test", useAlphaTest);
        widget.tooltip("Honor alpha-tested (cutout) materials when tracing rays.", true);
        return dirty;
    }
};
