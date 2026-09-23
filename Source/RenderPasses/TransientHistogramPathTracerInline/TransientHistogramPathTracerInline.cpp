/***************************************************************************
 # Copyright (c) 2015-24, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "TransientHistogramPathTracerInline.h"
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regTransientHistogramPathTracerInline(pybind11::module& m)
{
    pybind11::class_<TransientHistogramPathTracerInline, RenderPass, ref<TransientHistogramPathTracerInline>> pass(m, "TransientHistogramPathTracerInline");
    pass.def("reset_histogram", &TransientHistogramPathTracerInline::resetHistogram);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TransientHistogramPathTracerInline>();
    ScriptBindings::registerBinding(regTransientHistogramPathTracerInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TransientHistogramPathTracerInline/TransientHistogramPathTracerInline.cs.slang";
const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kLaserInputChannels = {
    // 1 x 1 laser hit buffer
    { "laservbuffer",        "gLaserVBuffer",     "Laser visibility buffer in packed format" },
    { "laserviewW",    "gLaserViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kOutputChannels = {
    { "color",          "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
};

const ChannelList kHistogramOutputChannelSingle = {
    { "histogram",          "gTransientHistogram", "Accumulated transient radiance density per bin", false, ResourceFormat::R32Float },
};

const ChannelList kHistogramOutputChannelsRGB = {
    { "histogram",          "gTransientHistogram", "Accumulated transient radiance density per bin", false, ResourceFormat::RGBA32Float },
};

const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kSamplesPerPixel[] = "samplesPerPixel";
const char kTimeGateMode[] = "timeGateMode";
const char kTimeMin[] = "timeMin";
const char kTimeMax[] = "timeMax";
const char kTimeBin[] = "timeBin";
const char kSamplingMethod[] = "samplingMethod";
const char kLaserCollocated[] = "laserCollocated";
const char kUseAlphaTest[] = "useAlphaTest";
const char kUseSingleChannel[] = "useSingleChannel";
const char kIsLightSourceLaser[] = "isLightSourceLaser";
const char kUseKernelDensityEstimation[] = "useKernelDensityEstimation";
const char kInitialWindowRatio[] = "initialWindowRatio";
const char kAutoReset[] = "autoReset";
const char kOutputSize[] = "outputSize";
const char kFixedOutputSize[] = "fixedOutputSize";

// Render data dictionary keys read by histogram consumers (e.g. TransientHistogramViewer).
const char kHistogramFrameCount[] = "transientHistogramFrameCount";
const char kHistogramTimeMin[] = "transientHistogramTimeMin";
const char kHistogramTimeMax[] = "transientHistogramTimeMax";
} // namespace

TransientHistogramPathTracerInline::TransientHistogramPathTracerInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void TransientHistogramPathTracerInline::resetHistogram()
{
    mNeedToClearHistogram = true;
}

void TransientHistogramPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxBounces)
            mOptions.maxBounces = value;
        else if (key == kComputeDirect)
            mOptions.computeDirect = value;
        else if (key == kUseImportanceSampling)
            mOptions.useImportanceSampling = value;
        else if (key == kSamplesPerPixel)
            mOptions.samplesPerPixel = value;
        else if (key == kTimeGateMode)
        {
            const std::string mode = value;
            auto it = TimeGateModeTable.find(mode);
            if (it == TimeGateModeTable.end()) FALCOR_THROW("Unknown timeGateMode '{}'.", mode);
            mOptions.timeGateMode = it->second;
        }
        else if (key == kTimeMin)
            mOptions.timeMin = value;
        else if (key == kTimeMax)
            mOptions.timeMax = value;
        else if (key == kTimeBin)
            mOptions.timeBin = value;
        else if (key == kSamplingMethod)
        {
            const std::string method = value;
            if (method == "direct") mOptions.samplingMethod = SamplingMethod::Direct;
            else if (method == "tri_approx") mOptions.samplingMethod = SamplingMethod::TriangleApprox;
            else FALCOR_THROW("samplingMethod must be direct or tri_approx.");
        }
        else if (key == kLaserCollocated)
            mOptions.laserCollocated = value;
        else if (key == kUseAlphaTest)
            mOptions.useAlphaTest = value;
        else if (key == kUseSingleChannel)
            mOptions.useSingleChannel = value;
        else if (key == kIsLightSourceLaser)
            mOptions.isLightSourceLaser = value;
        else if (key == kInitialWindowRatio)
            mOptions.initialWindowRatio = value;
        else if (key == kUseKernelDensityEstimation)
            mOptions.useKernelDensityEstimation = value;
        else if (key == kAutoReset)
            mOptions.autoReset = value;
        else if (key == kOutputSize)
            mOptions.outputSize = value;
        else if (key == kFixedOutputSize)
            mOptions.fixedOutputSize = value;
        else
            logWarning("Unknown property '{}' in TransientHistogramPathTracerInline properties.", key);
    }
}

void TransientHistogramPathTracerInline::validateOptions(const Options& options)
{
    if (!options.useKernelDensityEstimation && options.samplingMethod == SamplingMethod::Direct &&
        options.timeGateMode != TimeGateMode::BOX && options.timeGateMode != TimeGateMode::TENT)
        FALCOR_THROW("Without KDE, histogram filtering supports box or tent.");
    if (!std::isfinite(options.initialWindowRatio) || options.initialWindowRatio <= 0.f || options.initialWindowRatio > 1.f)
        FALCOR_THROW("initialWindowRatio must be finite and in (0, 1]. Zero would produce a zero KDE bandwidth.");
    if (!options.timeBin || !options.samplesPerPixel)
        FALCOR_THROW("timeBin and samplesPerPixel must be positive.");
    if (!std::isfinite(options.timeMin) || !std::isfinite(options.timeMax) || options.timeMin >= options.timeMax ||
        !std::isfinite(options.timeMax - options.timeMin) || (options.timeMax - options.timeMin) / options.timeBin <= 0.f)
        FALCOR_THROW("Histogram range must be finite with timeMin < timeMax and positive bin width.");
}

Properties TransientHistogramPathTracerInline::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mOptions.maxBounces;
    props[kComputeDirect] = mOptions.computeDirect;
    props[kUseImportanceSampling] = mOptions.useImportanceSampling;
    props[kSamplesPerPixel] = mOptions.samplesPerPixel;
    props[kTimeMin] = mOptions.timeMin;
    props[kTimeMax] = mOptions.timeMax;
    props[kTimeBin] = mOptions.timeBin;
    props[kLaserCollocated] = mOptions.laserCollocated;
    props[kUseAlphaTest] = mOptions.useAlphaTest;
    props[kUseSingleChannel] = mOptions.useSingleChannel;
    props[kIsLightSourceLaser] = mOptions.isLightSourceLaser;
    props[kUseKernelDensityEstimation] = mOptions.useKernelDensityEstimation;
    props[kInitialWindowRatio] = mOptions.initialWindowRatio;
    props[kSamplingMethod] = mOptions.samplingMethod == SamplingMethod::Direct ? "direct" : "tri_approx";
    props[kAutoReset] = mOptions.autoReset;
    props[kOutputSize] = mOptions.outputSize;
    if (mOptions.outputSize == RenderPassHelpers::IOSize::Fixed)
        props[kFixedOutputSize] = mOptions.fixedOutputSize;
    for (const auto& [name, mode] : TimeGateModeTable)
        if (mode == mOptions.timeGateMode) props[kTimeGateMode] = name;
    return props;
}

RenderPassReflection TransientHistogramPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    const uint2 sz = RenderPassHelpers::calculateIOSize(mOptions.outputSize, mOptions.fixedOutputSize, compileData.defaultTexDims);
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess, sz);

    const ChannelList& histogramChannels = mOptions.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;

    for (const auto& it : histogramChannels)
    {
        auto& tex = reflector.addOutput(it.name, it.desc).texture3D(sz.x, sz.y, mOptions.timeBin);
        tex.bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        if (it.format != ResourceFormat::Unknown)
            tex.format(it.format);
        if (it.optional)
            tex.flags(RenderPassReflection::Field::Flags::Optional);
    }

    return reflector;
}

void TransientHistogramPathTracerInline::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    // Recompilation may allocate a new histogram, for example after resizing.
    resetHistogram();
}

DefineList TransientHistogramPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines;

    defines.add("MAX_BOUNCES", std::to_string(mOptions.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.computeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.useImportanceSampling ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.useSingleChannel ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.isLightSourceLaser ? "1" : "0");
    defines.add("USE_KERNEL_DENSITY_ESTIMATION", mOptions.useKernelDensityEstimation ? "1" : "0");

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)SamplingMethod::Direct));
    defines.add("TRIANGLE_APPROX", std::to_string((uint32_t)SamplingMethod::TriangleApprox));

    defines.add("HISTOGRAM_FILTER", std::to_string((uint32_t)mOptions.timeGateMode));
    defines.add("HISTOGRAM_FILTER_BOX", std::to_string((uint32_t)TimeGateMode::BOX));
    defines.add("HISTOGRAM_FILTER_TENT", std::to_string((uint32_t)TimeGateMode::TENT));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    const ChannelList& histogramChannels = mOptions.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    defines.add(getValidResourceDefines(histogramChannels, renderData));

    return defines;
}

void TransientHistogramPathTracerInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    auto& dict = renderData.getDictionary();

    // Dispatch over the output, which may have a fixed size.
    const ref<Texture> pColor = renderData.getTexture("color");
    const uint2 targetDim = {pColor->getWidth(), pColor->getHeight()};

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = targetDim;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;

    // transients
    if (mOptions.laserCollocated)
    {
        var["CB"]["laserOrigin"] = mpScene->getCamera()->getPosition();
        var["CB"]["laserDirection"] = normalize(mpScene->getCamera()->getTarget() - mpScene->getCamera()->getPosition());
    }
    else
    {
        var["CB"]["laserOrigin"] = dict.keyExists("laserPosition") ? dict["laserPosition"] : float3(0,0,0);
        var["CB"]["laserDirection"] = dict.keyExists("laserDirection") ? dict["laserDirection"] : float3(0,0,1);
    }
    var["CB"]["laserPower"] = dict.keyExists("laserPower") ? dict["laserPower"] : float3(1,1,1);
    var["CB"]["laserCosAngle"] = dict.keyExists("laserCosAngle") ? dict["laserCosAngle"] : 0.0f;

    var["CB"]["samplesPerPixel"] = mOptions.samplesPerPixel;
    var["CB"]["initialWindowRatio"] = mOptions.initialWindowRatio;

    var["TimeGate"]["time_gate_mode"] = uint(mOptions.timeGateMode);

    var["TimeGate"]["tbin"] = mOptions.timeBin;
    var["TimeGate"]["tmax"] = mOptions.timeMax;
    var["TimeGate"]["tmin"] = mOptions.timeMin;
    var["TimeGate"]["tunit"] = (mOptions.timeMax - mOptions.timeMin) / mOptions.timeBin;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kLaserInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);

    const ChannelList& histogramChannels = mOptions.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
    for (auto channel : histogramChannels)
        bind(channel);
}

void TransientHistogramPathTracerInline::prepareProgram(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpComputePass)
    {
        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getShaderDefines(renderData));

        mpComputePass = ComputePass::create(mpDevice, desc, defines, true);

        // Bind static resources
        ShaderVar var = mpComputePass->getRootVar();
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        mpSampleGenerator->bindShaderData(var);
    }

}

void TransientHistogramPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
        for (auto it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        if (auto histogram = renderData.getTexture("histogram"))
            pRenderContext->clearTexture(histogram.get());
        return;
    }

    if (mOptions.autoReset && needsAutoReset(renderData))
        resetHistogram();
    if (mNeedToClearHistogram)
    {
        pRenderContext->clearTexture(renderData.getTexture("histogram").get());
        mNeedToClearHistogram = false;
        mHistogramFrameCount = 0;
    }

    // Triangle approximation enumerates all triangles; no triangle sampling distribution is needed.
    if (mOptions.samplingMethod == SamplingMethod::TriangleApprox)
        mpScene->getTriCollection(pRenderContext)->update(pRenderContext);
    prepareProgram(pRenderContext, renderData);

    if (is_set(mpScene->getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(mpScene->getUpdates(), IScene::UpdateFlags::GeometryChanged))
    {
        FALCOR_THROW("This render pass does not support scene changes that require shader recompilation.");
    }

    // Configure depth-of-field.
    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr)
    {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    // Specialize program.
    mpComputePass->getProgram()->addDefines(getShaderDefines(renderData));

    // bind variables
    auto var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    // Spawn the rays.
    const ref<Texture> pColor = renderData.getTexture("color");
    mpComputePass->execute(pRenderContext, uint3(pColor->getWidth(), pColor->getHeight(), 1));

    mFrameCount++;
    mHistogramFrameCount++;
    dict[kHistogramFrameCount] = mHistogramFrameCount;
    dict[kHistogramTimeMin] = mOptions.timeMin;
    dict[kHistogramTimeMax] = mOptions.timeMax;

}

bool TransientHistogramPathTracerInline::needsAutoReset(const RenderData& renderData) const
{
    // Same rule as AccumulatePass: any refresh flag or scene change except camera jitter/history.
    auto& dict = renderData.getDictionary();
    if (dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None) != RenderPassRefreshFlags::None)
        return true;
    const auto sceneUpdates = mpScene->getUpdates();
    if ((sceneUpdates & ~IScene::UpdateFlags::CameraPropertiesChanged) != IScene::UpdateFlags::None)
        return true;
    if (is_set(sceneUpdates, IScene::UpdateFlags::CameraPropertiesChanged))
    {
        const auto excluded = Camera::Changes::Jitter | Camera::Changes::History;
        if ((mpScene->getCamera()->getChanges() & ~excluded) != Camera::Changes::None)
            return true;
    }
    return false;
}

void TransientHistogramPathTracerInline::renderUI(Gui::Widgets& widget)
{
    Options options = mOptions;
    bool dirty = false;

    if (auto group = widget.group("Histogram", true))
    {
        dirty |= group.var("Range min", options.timeMin, 0.0f, 1000.0f);
        group.tooltip("Start of the histogram, in path-length units (total optical length laser -> scene -> camera).", true);

        dirty |= group.var("Range max", options.timeMax, 0.0f, 1000.0f);
        group.tooltip("End of the histogram, in path-length units. Paths outside [min, max) are not recorded.", true);

        dirty |= group.var("Bins", options.timeBin, 1u, 4096u);
        group.tooltip("Number of bins. The histogram texture holds width x height x bins values.", true);

        group.text(fmt::format("Bin width: {:.4f}", (options.timeMax - options.timeMin) / float(options.timeBin)));

        if (options.samplingMethod == SamplingMethod::Direct)
        {
            dirty |= group.checkbox("Kernel density estimation", options.useKernelDensityEstimation);
            group.tooltip("Spread each path over the bins with a kernel instead of adding it to the bin that contains "
                          "its length. The kernel narrows with each sample of a frame and restarts every frame.", true);

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
            uint32_t filter = (uint32_t)options.timeGateMode;
            if (group.dropdown("Filter", options.useKernelDensityEstimation ? kKernelList : kBinFilterList, filter))
            {
                options.timeGateMode = (TimeGateMode)filter;
                dirty = true;
            }
            group.tooltip("Without KDE: Box adds a path to its bin; Tent splits it between the two nearest bins.\n"
                          "With KDE: the kernel shape.", true);

            if (options.useKernelDensityEstimation)
            {
                dirty |= group.var("Initial KDE window ratio", options.initialWindowRatio, 0.0001f, 1.f);
                group.tooltip("Kernel width of a frame's first sample = histogram range x this ratio.", true);
            }
        }
    }

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= group.var("Samples per pixel", options.samplesPerPixel, 1u, 1024u);
        group.tooltip("Camera paths traced per pixel in each frame.", true);

        dirty |= group.var("Max bounces", options.maxBounces, 0u, 1u << 16);
        group.tooltip("Maximum number of surface vertices on the camera path, counting the primary hit. Each vertex "
                      "is connected to the laser spot.", true);

        static const Gui::DropdownList kSamplingMethodList = {
            {(uint32_t)SamplingMethod::Direct, "Direct"},
            {(uint32_t)SamplingMethod::TriangleApprox, "Triangle approximation"},
        };
        uint32_t samplingMethod = (uint32_t)options.samplingMethod;
        if (group.dropdown("Sampling method", kSamplingMethodList, samplingMethod))
        {
            options.samplingMethod = (SamplingMethod)samplingMethod;
            dirty = true;
        }
        group.tooltip("Direct: trace camera paths and connect each vertex to the laser spot.\n"
                      "Triangle approximation: integrate paths primary hit -> one scene triangle -> laser spot "
                      "over every triangle (a single intermediate bounce).", true);

        dirty |= group.checkbox("Primary-hit direct", options.computeDirect);
        group.tooltip("Include the shortest path, camera -> primary hit -> laser spot.", true);

        dirty |= group.checkbox("Use importance sampling", options.useImportanceSampling);
        group.tooltip("Importance-sample the BSDF when extending the camera path. Off: the material's reference "
                      "sampler (cosine-weighted for standard materials).", true);
    }

    if (auto group = widget.group("Light", true))
    {
        dirty |= group.checkbox("Laser source", options.isLightSourceLaser);
        group.tooltip("On: the light is the spot where the laser beam hits the scene, and the beam length adds to "
                      "the path length.\nOff: a point light at the laser position.", true);

        dirty |= group.checkbox("Laser collocated", options.laserCollocated);
        group.tooltip("Place the laser at the camera, aimed at the camera target, instead of using the laser pass "
                      "position and direction. The laser follows the camera when it moves.", true);
    }

    if (auto group = widget.group("Output", true))
    {
        dirty |= group.checkbox("Auto reset", options.autoReset);
        group.tooltip("Clear the histogram when the camera moves or an upstream pass changes its options. "
                      "Otherwise it accumulates until reset.", true);

        dirty |= group.checkbox("Single channel", options.useSingleChannel);
        group.tooltip("Store only the red channel (one float per bin instead of four).", true);

        dirty |= group.checkbox("Alpha test", options.useAlphaTest);
        group.tooltip("Honor alpha-tested (cutout) materials when tracing rays.", true);

        if (group.button("Reset histogram"))
            resetHistogram();
        group.text(fmt::format("Accumulated frames: {}", mHistogramFrameCount));
    }

    if (dirty)
    {
        // Keep the filter valid when KDE is switched off.
        if (!options.useKernelDensityEstimation && options.timeGateMode != TimeGateMode::BOX &&
            options.timeGateMode != TimeGateMode::TENT)
            options.timeGateMode = TimeGateMode::BOX;
        try
        {
            validateOptions(options);
        }
        catch (const std::exception& e)
        {
            mUIWarning = e.what();
            return;
        }
        mUIWarning.clear();
        // The histogram texture depends on the bin count and channel count.
        const bool resize = options.timeBin != mOptions.timeBin || options.useSingleChannel != mOptions.useSingleChannel;
        mOptions = options;
        mOptionsChanged = true;
        resetHistogram();
        if (resize)
            requestRecompile();
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void TransientHistogramPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mpComputePass = nullptr;
    mFrameCount = 0;
    resetHistogram();

    // Set new scene.
    mpScene = pScene;
}
