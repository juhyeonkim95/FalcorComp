#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"

/// Camera paths and the output. The light is set on the laser pass (LaserVBufferRT, see LaserState).
struct PathTracingConfig
{
    uint samplesPerPixel = 128;
    uint maxBounces = 3; ///< Maximum surface vertices on a camera path, counting the primary hit.
    bool computeDirect = false; ///< Include camera -> primary hit -> laser spot.
    bool useImportanceSampling = true;
    bool useAlphaTest = false;
    bool useSingleChannel = false;

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
            widget.tooltip("Copy the red channel to green and blue.", true);
        }
        dirty |= widget.checkbox("Alpha test", useAlphaTest);
        widget.tooltip("Honor alpha-tested (cutout) materials when tracing rays.", true);
        return dirty;
    }
};
