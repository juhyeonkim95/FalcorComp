#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"
#include "Utils/Transient/Transient.h"
#include <cmath>

/// Transient histogram: timeBin bins over path lengths [timeMin, timeMax), filled with a bin filter or,
/// with kernel density estimation, a kernel.
struct TransientHistogramConfig
{
    // Render data dictionary keys shared by the histogram passes (tracers, accumulation, viewer).
    static constexpr char kTimeMinKey[] = "transientHistogramTimeMin";
    static constexpr char kTimeMaxKey[] = "transientHistogramTimeMax";
    /// Frames summed into the histogram: the histogram divided by it is the mean (1 for a mean or a single frame).
    static constexpr char kSummedFramesKey[] = "transientHistogramSummedFrames";
    /// Frames in the mean, for display.
    static constexpr char kAveragedFramesKey[] = "transientHistogramAveragedFrames";

    float timeMin = 9.f;
    float timeMax = 12.f;
    uint timeBin = 512;
    TimeGateMode filter = TimeGateMode::BOX; ///< Bin filter (Box/Tent), or the kernel with KDE.
    bool useKernelDensityEstimation = false;
    float initialWindowRatio = 1.f;          ///< KDE: kernel width of a frame's first sample / histogram range, in (0, 1].

    float binWidth() const { return (timeMax - timeMin) / float(timeBin); }

    /// Stores the histogram range for the passes downstream (e.g. TransientHistogramViewer).
    void publishRange(const RenderData& renderData) const
    {
        auto& dict = renderData.getDictionary();
        dict[kTimeMinKey] = timeMin;
        dict[kTimeMaxKey] = timeMax;
    }

    /// Sets the histogram constants (filter, tbin, tmin, tmax, tunit) under `timeGateVar`.
    void bindShaderData(const ShaderVar& timeGateVar) const
    {
        timeGateVar["time_gate_mode"] = uint(filter);
        timeGateVar["tbin"] = timeBin;
        timeGateVar["tmin"] = timeMin;
        timeGateVar["tmax"] = timeMax;
        timeGateVar["tunit"] = binWidth();
    }

    void validate() const
    {
        if (timeBin == 0)
            FALCOR_THROW("timeBin must be positive.");
        if (!std::isfinite(timeMin) || !std::isfinite(timeMax) || timeMin >= timeMax || !(binWidth() > 0.f))
            FALCOR_THROW("Histogram range must be finite with timeMin < timeMax and positive bin width.");
        if (!std::isfinite(initialWindowRatio) || initialWindowRatio <= 0.f || initialWindowRatio > 1.f)
            FALCOR_THROW("initialWindowRatio must be finite and in (0, 1]. Zero would produce a zero KDE bandwidth.");
    }

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "timeMin")
            timeMin = value;
        else if (key == "timeMax")
            timeMax = value;
        else if (key == "timeBin")
            timeBin = value;
        else if (key == "timeGateMode")
            filter = parseEnumProperty(TimeGateModeTable, std::string(value), key);
        else if (key == "useKernelDensityEstimation")
            useKernelDensityEstimation = value;
        else if (key == "initialWindowRatio")
            initialWindowRatio = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["timeMin"] = timeMin;
        props["timeMax"] = timeMax;
        props["timeBin"] = timeBin;
        props["timeGateMode"] = enumPropertyName(TimeGateModeTable, filter);
        props["useKernelDensityEstimation"] = useKernelDensityEstimation;
        props["initialWindowRatio"] = initialWindowRatio;
    }

    /// Range, bins and filter. `allowKernelDensityEstimation` shows the KDE controls.
    bool renderUI(Gui::Widgets& widget, bool allowKernelDensityEstimation)
    {
        bool dirty = false;
        dirty |= widget.var("Range min", timeMin, 0.0f, 1000.0f);
        widget.tooltip("Start of the histogram, in path-length units (total optical length laser -> scene -> camera).", true);

        dirty |= widget.var("Range max", timeMax, 0.0f, 1000.0f);
        widget.tooltip("End of the histogram, in path-length units. Paths outside [min, max) are not recorded.", true);

        dirty |= widget.var("Bins", timeBin, 1u, 4096u);
        widget.tooltip("Number of bins. The histogram texture holds width x height x bins values.", true);

        widget.text(fmt::format("Bin width: {:.4f}", binWidth()));

        if (allowKernelDensityEstimation)
        {
            dirty |= widget.checkbox("Kernel density estimation", useKernelDensityEstimation);
            widget.tooltip("Spread each path over the bins with a kernel instead of adding it to the bin that contains "
                           "its length. The kernel narrows with each sample of a frame and restarts every frame.", true);
        }
        const bool kde = allowKernelDensityEstimation && useKernelDensityEstimation;

        // Kernels implemented by the histogram filters in TransientUtils.
        static const Gui::DropdownList kBinFilterList = {
            {(uint32_t)TimeGateMode::BOX, "Box"},
            {(uint32_t)TimeGateMode::TENT, "Tent"},
        };
        static const Gui::DropdownList kKernelList = {
            {(uint32_t)TimeGateMode::BOX, "Box"},
            {(uint32_t)TimeGateMode::TENT, "Tent"},
            {(uint32_t)TimeGateMode::GAUSSIAN, "Gaussian"},
            {(uint32_t)TimeGateMode::EPANECHNIKOV, "Epanechnikov"},
            {(uint32_t)TimeGateMode::PERLIN, "Perlin"},
        };
        uint32_t mode = (uint32_t)filter;
        if (widget.dropdown("Filter", kde ? kKernelList : kBinFilterList, mode))
        {
            filter = (TimeGateMode)mode;
            dirty = true;
        }
        widget.tooltip("Without KDE: Box adds a path to its bin; Tent splits it between the two nearest bins.\n"
                       "With KDE: the kernel shape.", true);

        if (kde)
        {
            dirty |= widget.var("Initial KDE window ratio", initialWindowRatio, 0.0001f, 1.f);
            widget.tooltip("Kernel width of a frame's first sample = histogram range x this ratio.", true);
        }
        // Keep the filter valid when KDE is off.
        if (!useKernelDensityEstimation && filter != TimeGateMode::BOX && filter != TimeGateMode::TENT)
        {
            filter = TimeGateMode::BOX;
            dirty = true;
        }
        return dirty;
    }
};
