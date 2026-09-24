#pragma once
#include "Falcor.h"
#include "Utils/Transient/Transient.h"
#include "Rendering/Lights/EmissiveLightSamplerType.slangh"
#include <cmath>
#include <string>
#include <unordered_map>

using namespace Falcor;

/** Options shared by the time-gated render passes (TimeGatedPathTracerInline, TimeGatedReSTIRInline).
 * Each group parses and serializes its own render pass properties.
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

    /// Returns false if `key` is not a time gate property.
    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "timeMin")
            timeMin = value;
        else if (key == "timeMax")
            timeMax = value;
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

    void serialize(Properties& props) const
    {
        props["timeMin"] = timeMin;
        props["timeMax"] = timeMax;
        props["timeBin"] = timeBin;
        props["timeGateWindow"] = timeGateWindow;
        props["timeGateMode"] = enumPropertyName(TimeGateModeTable, timeGateMode);
        props["shiftGate"] = shiftGate;
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
};
