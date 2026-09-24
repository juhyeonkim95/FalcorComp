#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"

/// Channel kept by single-channel rendering (SINGLE_CHANNEL in Shared/Utils/SingleChannel.slang).
enum class SingleChannel : uint32_t
{
    Luminance = 0,
    Red = 1,
    Green = 2,
    Blue = 3,
};

inline const std::unordered_map<std::string, SingleChannel> kSingleChannels = {
    {"luminance", SingleChannel::Luminance},
    {"red", SingleChannel::Red},
    {"green", SingleChannel::Green},
    {"blue", SingleChannel::Blue},
};

/// Camera paths and the output. The light is set on the laser pass (LaserVBufferRT, see LaserState).
struct PathTracingConfig
{
    uint samplesPerPixel = 128;
    uint maxBounces = 3; ///< Maximum surface vertices on a camera path, counting the primary hit.
    bool computeDirect = false; ///< Include camera -> primary hit -> laser spot.
    bool useImportanceSampling = true;
    bool useAlphaTest = false;
    bool useSingleChannel = false;
    SingleChannel singleChannel = SingleChannel::Red; ///< Channel kept by useSingleChannel.

    void validate() const
    {
        if (samplesPerPixel == 0)
            FALCOR_THROW("samplesPerPixel must be greater than zero.");
    }

    /// MAX_BOUNCES, COMPUTE_DIRECT, USE_IMPORTANCE_SAMPLING, USE_ALPHA_TEST, USE_SINGLE_CHANNEL.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("MAX_BOUNCES", std::to_string(maxBounces));
        defines.add("COMPUTE_DIRECT", computeDirect ? "1" : "0");
        defines.add("USE_IMPORTANCE_SAMPLING", useImportanceSampling ? "1" : "0");
        defines.add("USE_ALPHA_TEST", useAlphaTest ? "1" : "0");
        defines.add("USE_SINGLE_CHANNEL", useSingleChannel ? "1" : "0");
        defines.add("SINGLE_CHANNEL", std::to_string((uint32_t)singleChannel));
        return defines;
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
        else if (key == "singleChannel")
            singleChannel = parseEnumProperty(kSingleChannels, std::string(value), key);
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
        props["singleChannel"] = enumPropertyName(kSingleChannels, singleChannel);
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
            widget.tooltip("Keep one channel. The time-gated path tracer writes it to all three; the histogram passes "
                           "store one float per bin.", true);
            if (useSingleChannel)
            {
                static const Gui::DropdownList kChannelList = {
                    {(uint32_t)SingleChannel::Luminance, "Luminance"},
                    {(uint32_t)SingleChannel::Red, "Red"},
                    {(uint32_t)SingleChannel::Green, "Green"},
                    {(uint32_t)SingleChannel::Blue, "Blue"},
                };
                uint32_t channel = (uint32_t)singleChannel;
                if (widget.dropdown("Channel", kChannelList, channel))
                {
                    singleChannel = (SingleChannel)channel;
                    dirty = true;
                }
            }
        }
        dirty |= widget.checkbox("Alpha test", useAlphaTest);
        widget.tooltip("Honor alpha-tested (cutout) materials when tracing rays.", true);
        return dirty;
    }
};
