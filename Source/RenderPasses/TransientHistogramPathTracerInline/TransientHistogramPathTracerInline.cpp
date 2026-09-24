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

const char kSamplingMethod[] = "samplingMethod";
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
        if (mOptions.histogram.parse(key, value) || mOptions.pathTracing.parse(key, value))
            continue;
        if (key == kSamplingMethod)
        {
            const std::string method = value;
            if (method == "direct") mOptions.samplingMethod = SamplingMethod::Direct;
            else if (method == "tri_approx") mOptions.samplingMethod = SamplingMethod::TriangleApprox;
            else FALCOR_THROW("samplingMethod must be direct or tri_approx.");
        }
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
    options.histogram.validate();
    options.pathTracing.validate();
    if (!options.histogram.useKernelDensityEstimation && options.samplingMethod == SamplingMethod::Direct &&
        options.histogram.filter != TimeGateMode::BOX && options.histogram.filter != TimeGateMode::TENT)
        FALCOR_THROW("Without KDE, histogram filtering supports box or tent.");
}

Properties TransientHistogramPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.histogram.serialize(props);
    mOptions.pathTracing.serialize(props);
    props[kSamplingMethod] = mOptions.samplingMethod == SamplingMethod::Direct ? "direct" : "tri_approx";
    props[kAutoReset] = mOptions.autoReset;
    props[kOutputSize] = mOptions.outputSize;
    if (mOptions.outputSize == RenderPassHelpers::IOSize::Fixed)
        props[kFixedOutputSize] = mOptions.fixedOutputSize;
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

    const ChannelList& histogramChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;

    for (const auto& it : histogramChannels)
    {
        auto& tex = reflector.addOutput(it.name, it.desc).texture3D(sz.x, sz.y, mOptions.histogram.timeBin);
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

    defines.add("MAX_BOUNCES", std::to_string(mOptions.pathTracing.maxBounces));
    defines.add("COMPUTE_DIRECT", mOptions.pathTracing.computeDirect ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("IS_LIGHT_SOURCE_LASER", mOptions.pathTracing.isLightSourceLaser ? "1" : "0");
    defines.add("USE_KERNEL_DENSITY_ESTIMATION", mOptions.histogram.useKernelDensityEstimation ? "1" : "0");

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)SamplingMethod::Direct));
    defines.add("TRIANGLE_APPROX", std::to_string((uint32_t)SamplingMethod::TriangleApprox));

    defines.add("HISTOGRAM_FILTER", std::to_string((uint32_t)mOptions.histogram.filter));
    defines.add("HISTOGRAM_FILTER_BOX", std::to_string((uint32_t)TimeGateMode::BOX));
    defines.add("HISTOGRAM_FILTER_TENT", std::to_string((uint32_t)TimeGateMode::TENT));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));

    const ChannelList& histogramChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
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
    if (mOptions.pathTracing.laserCollocated)
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

    var["CB"]["samplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["initialWindowRatio"] = mOptions.histogram.initialWindowRatio;

    var["TimeGate"]["time_gate_mode"] = uint(mOptions.histogram.filter);

    var["TimeGate"]["tbin"] = mOptions.histogram.timeBin;
    var["TimeGate"]["tmax"] = mOptions.histogram.timeMax;
    var["TimeGate"]["tmin"] = mOptions.histogram.timeMin;
    var["TimeGate"]["tunit"] = (mOptions.histogram.timeMax - mOptions.histogram.timeMin) / mOptions.histogram.timeBin;

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

    const ChannelList& histogramChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
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
    dict[kHistogramTimeMin] = mOptions.histogram.timeMin;
    dict[kHistogramTimeMax] = mOptions.histogram.timeMax;

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
        dirty |= options.histogram.renderUI(group, options.samplingMethod == SamplingMethod::Direct);

    if (auto group = widget.group("Sampling", true))
    {
        dirty |= options.pathTracing.renderSamplingUI(group, " Each vertex is connected to the laser spot.");

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
    }

    if (auto group = widget.group("Light", true))
        dirty |= options.pathTracing.renderLightUI(group);

    if (auto group = widget.group("Output", true))
    {
        dirty |= options.pathTracing.renderOutputUI(group, true);

        dirty |= group.checkbox("Auto reset", options.autoReset);
        group.tooltip("Clear the histogram when the camera moves or an upstream pass changes its options. "
                      "Otherwise it accumulates until reset.", true);

        if (group.button("Reset histogram"))
            resetHistogram();
        group.text(fmt::format("Accumulated frames: {}", mHistogramFrameCount));
    }

    if (dirty)
    {
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
        const bool resize = options.histogram.timeBin != mOptions.histogram.timeBin || options.pathTracing.useSingleChannel != mOptions.pathTracing.useSingleChannel;
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
