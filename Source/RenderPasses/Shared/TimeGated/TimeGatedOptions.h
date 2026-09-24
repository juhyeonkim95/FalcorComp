#pragma once
#include "Falcor.h"
#include "Utils/Transient/Transient.h"
#include "Rendering/Lights/EmissiveLightSamplerType.slangh"
#include <cmath>
#include <string>
#include <unordered_map>

using namespace Falcor;

/** Options shared by the time-gated render passes (TimeGatedPathTracerInline, TimeGatedReSTIRInline).
 * Each group parses and serializes its own render pass properties and draws its UI controls
 * (renderUI functions return true when a value changed).
 */

enum class TimeGatedSamplingMethod
{
    DIRECT = 0,
    ELLIPSOIDAL = 1,
    ELLIPSOIDAL_DIRECT_MIS = 2,
};

inline const std::unordered_map<std::string, TimeGatedSamplingMethod> kTimeGatedSamplingMethods = {
    {"direct", TimeGatedSamplingMethod::DIRECT},
    {"ellipsoidal", TimeGatedSamplingMethod::ELLIPSOIDAL},
    {"ellipsoidal_direct_mis", TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS},
};

template<typename T>
T parseEnumProperty(const std::unordered_map<std::string, T>& values, const std::string& name, const std::string& key)
{
    auto it = values.find(name);
    if (it == values.end())
        FALCOR_THROW("Invalid value '{}' for '{}'.", name, key);
    return it->second;
}

template<typename T>
std::string enumPropertyName(const std::unordered_map<std::string, T>& values, T value)
{
    for (const auto& [name, candidate] : values)
        if (candidate == value)
            return name;
    FALCOR_THROW("Cannot serialize invalid enum value.");
}

/// Time gate: a kernel of width timeGateWindow whose center scans timeBin positions in [timeMin, timeMax).
struct TimeGateConfig
{
    float timeMin = 9.0f;
    float timeMax = 12.0f;
    uint timeBin = 512;
    float timeGateWindow = 0.05f;
    TimeGateMode timeGateMode = TimeGateMode::BOX;
    bool shiftGate = false; ///< Advance the gate one bin per frame, wrapping from timeMax to timeMin.

    /// Center of gate `index`. Equal endpoints give a fixed gate.
    float gateCenter(uint index) const { return float(index % timeBin) / timeBin * (timeMax - timeMin) + timeMin; }

    void validate() const
    {
        if (timeBin == 0)
            FALCOR_THROW("timeBin must be greater than zero.");
        if (!std::isfinite(timeGateWindow) || timeGateWindow <= 0.f)
            FALCOR_THROW("timeGateWindow must be finite and greater than zero.");
        if (!std::isfinite(timeMin) || !std::isfinite(timeMax) || timeMin > timeMax)
            FALCOR_THROW("The gate range must be finite with timeMin <= timeMax.");
    }

    /// Returns false if `key` is not a time gate property. "timeCenter" is applied by applyTimeCenter().
    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "timeMin")
            timeMin = value;
        else if (key == "timeMax")
            timeMax = value;
        else if (key == "timeCenter")
            ; // Applied after all properties, so it overrides timeMin and timeMax in any order.
        else if (key == "timeBin")
            timeBin = value;
        else if (key == "timeGateWindow")
            timeGateWindow = value;
        else if (key == "timeGateMode")
            timeGateMode = parseEnumProperty(TimeGateModeTable, std::string(value), key);
        else if (key == "shiftGate")
            shiftGate = value;
        else
            return false;
        return true;
    }

    /// Optional "timeCenter": a fixed gate, timeMin = timeMax = timeCenter. Call after parsing.
    void applyTimeCenter(const Properties& props)
    {
        if (props.has("timeCenter"))
            timeMin = timeMax = props.get<float>("timeCenter");
    }

    void serialize(Properties& props) const
    {
        props["timeMin"] = timeMin;
        props["timeMax"] = timeMax;
        props["timeBin"] = timeBin;
        props["timeGateWindow"] = timeGateWindow;
        props["timeGateMode"] = enumPropertyName(TimeGateModeTable, timeGateMode);
        props["shiftGate"] = shiftGate;
    }

    /// Gate kernel, window and center (fixed or shifting). `shiftGateNote` is appended to the Shift gate tooltip.
    bool renderUI(Gui::Widgets& widget, float currentCenter, const std::string& shiftGateNote = "")
    {
        bool dirty = false;
        // Only the kernels implemented by pathLengthImportance() are offered.
        static const Gui::DropdownList kTimeGateModeList = {
            {(uint32_t)TimeGateMode::BOX, "Box"},
            {(uint32_t)TimeGateMode::TENT, "Tent"},
            {(uint32_t)TimeGateMode::COS, "Cos"},
            {(uint32_t)TimeGateMode::ALL, "All (no gating)"},
        };
        uint32_t mode = (uint32_t)timeGateMode;
        if (widget.dropdown("Gate kernel", kTimeGateModeList, mode))
        {
            timeGateMode = (TimeGateMode)mode;
            dirty = true;
        }
        widget.tooltip("Weight of a path as a function of its total optical length (laser -> scene -> camera) "
                       "relative to the gate center.", true);

        dirty |= widget.var("Gate window", timeGateWindow, 0.001f, 1000.0f);
        widget.tooltip("Gate width in path-length units (scene units). The output is divided by it.", true);

        if (widget.checkbox("Shift gate", shiftGate))
        {
            // Start a shifting scan from a fixed gate with a default range and resolution.
            if (shiftGate && timeMax <= timeMin)
            {
                timeMax = 1.2f * timeMin;
                timeBin = 100;
            }
            dirty = true;
        }
        widget.tooltip("Off: a fixed gate at Gate center.\nOn: the gate moves one step per frame from Gate min "
                       "toward Gate max, then starts again at Gate min." + shiftGateNote +
                       " Turning it on from a fixed gate sets Gate max = 1.2 x Gate min and 100 bins.", true);

        if (!shiftGate)
        {
            float center = timeMin;
            if (widget.var("Gate center", center, 0.0f, 1000.0f))
            {
                timeMin = timeMax = center;
                dirty = true;
            }
            widget.tooltip("Gate center in path-length units.", true);
        }
        else
        {
            dirty |= widget.var("Gate min", timeMin, 0.0f, timeMax);
            widget.tooltip("First gate center, in path-length units.", true);

            dirty |= widget.var("Gate max", timeMax, timeMin, 1000.0f);
            widget.tooltip("End of the scan, in path-length units. The last gate center is Gate max - Gate step.", true);

            dirty |= widget.var("Gate bins", timeBin, 1u, 1u << 16);
            widget.tooltip("Number of gate centers from Gate min to Gate max.", true);

            // The step is derived from the bins; editing it picks the nearest bin count.
            const float range = timeMax - timeMin;
            float gateStep = range / timeBin;
            if (range > 0.f && widget.var("Gate step", gateStep, 1e-4f, range))
            {
                timeBin = std::max(1u, (uint)std::lround(range / gateStep));
                dirty = true;
            }
            widget.tooltip("Gate center shift per frame, in path-length units. Sets Gate bins to the nearest count.", true);
            if (range <= 0.f)
                widget.text("Set Gate max above Gate min to shift the gate.");
        }

        widget.text(fmt::format("Current gate center: {:.4f}", currentCenter));
        return dirty;
    }
};

/// How a camera-path vertex is connected to the laser spot.
struct SamplingConfig
{
    TimeGatedSamplingMethod samplingMethod = TimeGatedSamplingMethod::DIRECT;
    EmissiveLightSamplerType triSampler = EmissiveLightSamplerType::LightBVH; ///< Picks the triangle of an ellipsoidal connection.
    float ellipsoidRoughnessThreshold = 0.25f; ///< ELLIPSOIDAL only: minimum roughness for an ellipsoidal connection.

    bool usesEllipsoid() const { return samplingMethod != TimeGatedSamplingMethod::DIRECT; }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "samplingMethod")
            samplingMethod = parseEnumProperty(kTimeGatedSamplingMethods, std::string(value), key);
        else if (key == "emissiveSampler")
            triSampler = value;
        else if (key == "specularRoughnessThresholdEllipsoid")
            ellipsoidRoughnessThreshold = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["samplingMethod"] = enumPropertyName(kTimeGatedSamplingMethods, samplingMethod);
        props["emissiveSampler"] = triSampler;
        props["specularRoughnessThresholdEllipsoid"] = ellipsoidRoughnessThreshold;
    }

    /// Sampling method, and the ellipsoid threshold and triangle sampler when they apply.
    bool renderUI(Gui::Widgets& widget, bool allowPowerSampler)
    {
        bool dirty = false;
        static const Gui::DropdownList kSamplingMethodList = {
            {(uint32_t)TimeGatedSamplingMethod::DIRECT, "Direct"},
            {(uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL, "Ellipsoidal"},
            {(uint32_t)TimeGatedSamplingMethod::ELLIPSOIDAL_DIRECT_MIS, "Ellipsoidal + direct (MIS)"},
        };
        uint32_t method = (uint32_t)samplingMethod;
        if (widget.dropdown("Sampling method", kSamplingMethodList, method))
        {
            samplingMethod = (TimeGatedSamplingMethod)method;
            dirty = true;
        }
        widget.tooltip("How a camera-path vertex x is connected to the laser spot:\n"
                       "Direct: connect x -> laser spot.\n"
                       "Ellipsoidal: insert a vertex y on the ellipsoid of paths x -> y -> laser spot whose length "
                       "matches the gate.\n"
                       "Ellipsoidal + direct (MIS): both, combined with the balance heuristic.", true);

        if (samplingMethod == TimeGatedSamplingMethod::ELLIPSOIDAL)
        {
            dirty |= widget.var("Ellipsoid roughness threshold", ellipsoidRoughnessThreshold, 0.f, 1.f);
            widget.tooltip("Use an ellipsoidal connection at x only if its roughness is above this value; smoother "
                           "vertices use a direct connection from the next vertex instead.", true);
        }

        if (usesEllipsoid())
        {
            Gui::DropdownList samplers = {
                {(uint32_t)EmissiveLightSamplerType::Uniform, "Uniform"},
                {(uint32_t)EmissiveLightSamplerType::LightBVH, "LightBVH"},
            };
            if (allowPowerSampler)
                samplers.push_back({(uint32_t)EmissiveLightSamplerType::Power, "Power"});
            uint32_t sampler = (uint32_t)triSampler;
            if (widget.dropdown("Ellipsoid triangle sampler", samplers, sampler))
            {
                triSampler = (EmissiveLightSamplerType)sampler;
                dirty = true;
            }
            widget.tooltip("How an ellipsoidal connection selects the scene triangle on which it places y.", true);
        }
        return dirty;
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
