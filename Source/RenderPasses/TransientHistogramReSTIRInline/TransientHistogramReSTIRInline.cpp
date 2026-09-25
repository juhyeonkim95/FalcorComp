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
#include "TransientHistogramReSTIRInline.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regTransientHistogramReSTIRInline(pybind11::module& m)
{
    pybind11::class_<TransientHistogramReSTIRInline, RenderPass, ref<TransientHistogramReSTIRInline>> pass(m, "TransientHistogramReSTIRInline");
    // pass.def_property("m", &MinimalTimeGatedPathTracer::isEnabled, &MinimalTimeGatedPathTracer::setEnabled);
    pass.def("reset_histogram", &TransientHistogramReSTIRInline::resetHistogram);
}


extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TransientHistogramReSTIRInline>();
    ScriptBindings::registerBinding(regTransientHistogramReSTIRInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TransientHistogramReSTIRInline/InitialSampleGeneration.cs.slang";
const char kReflectTypesFile[] = "RenderPasses/TransientHistogramReSTIRInline/ReflectTypes.cs.slang";
const char kSpatialReuseFile[] = "RenderPasses/TransientHistogramReSTIRInline/SpatialReuse.cs.slang";
const char kInputViewDir[] = "viewW";
const char kInputMotionVectors[] = "mvec";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputMotionVectors,  "gMotionVector",   "Motion vector buffer (float format)", true /* optional */ },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kLaserInputChannels = {
    // 1 x 1 laser hit buffer
    { "laservbuffer",  "gLaserVBuffer",     "Laser visibility buffer in packed format", true /* optional */ },
    { "laserviewW",    "gLaserViewW",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kLaserHitInputChannels = {
    // shadow map from laser hit point
    { "laserhitvbuffer",  "gLaserHitVBuffer",     "Laser visibility buffer in packed format", true /* optional */ },
    { "laserhitviewW",    "gLaserHitViewW",       "World-space view direction (xyz float format)", true /* optional */ },
    { "laserhitdepth",    "gLaserHitDepth",       "World-space view direction (xyz float format)", true /* optional */ },
};

const ChannelList kOutputChannels = {
    // clang-format off
    { "color",          "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const ChannelList kHistogramOutputChannelsRGB = {
    // clang-format off
    { "histogram",          "gTransientHistogram", "Output color", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const ChannelList kHistogramOutputChannelSingle = {
    // clang-format off
    { "histogram",          "gTransientHistogram", "Output color", false, ResourceFormat::R32Float },
    // clang-format on
};

const char kUseBinReuse[] = "useBinReuse";
const char kRandomSeed[] = "randomSeed";
} // namespace

TransientHistogramReSTIRInline::TransientHistogramReSTIRInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void TransientHistogramReSTIRInline::resetHistogram()
{
    mNeedToClearHistogram = true;
}


void TransientHistogramReSTIRInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.histogram.parse(key, value) || mOptions.pathTracing.parse(key, value) ||
            mOptions.restir.parse(key, value))
            continue;
        if (key == kUseBinReuse)
            mOptions.useBinReuse = value;
        else if (key == kRandomSeed)
            mRandomSeed = value;
        else
            logWarning("Unknown property '{}' in TransientHistogramReSTIRInline properties.", key);
    }
}

Properties TransientHistogramReSTIRInline::getProperties() const
{
    Properties props;
    mOptions.histogram.serialize(props);
    mOptions.pathTracing.serialize(props);
    mOptions.restir.serialize(props);
    props[kUseBinReuse] = mOptions.useBinReuse;
    props[kRandomSeed] = mRandomSeed;
    return props;
}

RenderPassReflection TransientHistogramReSTIRInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassInputs(reflector, kLaserHitInputChannels, ResourceBindFlags::ShaderResource, mOptions.restir.laserHitVBufferRes);
    addRenderPassOutputs(reflector, kOutputChannels);

    ChannelList kHistogramOutputChannels = mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;

    for (const auto& it : kHistogramOutputChannels)
    {
        auto& tex = reflector.addOutput(it.name, it.desc).texture3D(0, 0, mOptions.histogram.timeBin);
        tex.bindFlags(ResourceBindFlags::UnorderedAccess);
        if (it.format != ResourceFormat::Unknown)
            tex.format(it.format);
        if (it.optional)
            tex.flags(RenderPassReflection::Field::Flags::Optional);
    }

    return reflector;
}

DefineList TransientHistogramReSTIRInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(LaserState::resolve(renderData).getDefines());
    defines.add(InlinePass::getSceneLightDefines(*mpScene));
    defines.add(mOptions.restir.getDefines());
    defines.add("RESERVOIR_SCALAR_TARGET", mOptions.pathTracing.useSingleChannel ? "1" : "0");

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserHitInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));
    defines.add(getValidResourceDefines(histogramChannels(), renderData));
    return defines;
}

DefineList TransientHistogramReSTIRInline::getReservoirDefines() const
{
    // The reservoir layout depends on these (see ReflectTypes.cs.slang).
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("RESERVOIR_SCALAR_TARGET", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    return defines;
}

const ChannelList& TransientHistogramReSTIRInline::histogramChannels() const
{
    return mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
}

void TransientHistogramReSTIRInline::bindTimeGate(const ShaderVar& timeGateVar) const
{
    // Each bin is a box gate one bin wide.
    mOptions.histogram.bindShaderData(timeGateVar);
    timeGateVar["time_gate_window"] = mOptions.histogram.binWidth();
    timeGateVar["time_gate_window_rough"] = mOptions.histogram.binWidth();
}

void TransientHistogramReSTIRInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    var["prevReservoirs"] = mReSTIR.prevReservoirs;
    var["currReservoirs"] = mReSTIR.currReservoirs;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gRandomSeed"] = mRandomSeed;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gPRNGDimension"] = InlinePass::getPRNGDimension(renderData);
    var["CB"]["gLaserHitVBufferRes"] = mOptions.restir.laserHitVBufferRes;
    var["CB"]["specularRoughnessThreshold"] = mOptions.restir.reconnectionRoughnessThreshold;
    var["CB"]["samplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gTemporalHistoryLength"] = mOptions.restir.temporalHistoryLength;
    mLaser.bindShaderData(var["Laser_CB"]);
    bindTimeGate(var["TimeGate"]);

    if (mOptions.restir.useTemporalReuse)
    {
        // Temporal reuse shifts last frame's paths in this pass.
        var["gTemporalVBuffer"] = mReSTIR.temporalVBuffer;
        var["CB"]["gTemporalHistoryValid"] = mReSTIR.temporalHistoryValid;
        var["CB"]["gPreviousCameraPosition"] = mReSTIR.previousCameraPosition;
        mOptions.restir.bindShiftMapping(var["Shiftmap_CB"]);
    }

    InlinePass::bindChannels(var, renderData, kInputChannels);
    InlinePass::bindChannels(var, renderData, kLaserInputChannels);
    InlinePass::bindChannels(var, renderData, kLaserHitInputChannels);
    InlinePass::bindChannels(var, renderData, kOutputChannels);
    InlinePass::bindChannels(var, renderData, histogramChannels());
}

void TransientHistogramReSTIRInline::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
{
    mpSpatialReusePass->getProgram()->addDefines(getShaderDefines(renderData));
    auto rootVar = mpSpatialReusePass->getRootVar();
    auto var = rootVar["CB"]["gSpatialReuse"];
    const uint2 frameDim = renderData.getDefaultTextureDims();

    var["gFrameCount"] = mFrameCount;
    var["gFrameDim"] = frameDim;
    var["neighborOffsets"] = mReSTIR.neighborOffsets;
    var["useBinReuse"] = mOptions.useBinReuse;
    mOptions.restir.bindSpatialReuse(var);

    InlinePass::bindChannels(var, renderData, kInputChannels);
    InlinePass::bindChannels(var, renderData, kLaserInputChannels);
    InlinePass::bindChannels(var, renderData, kOutputChannels);
    // The histogram is a pass-level global, outside the shared SpatialReuse struct.
    InlinePass::bindChannels(rootVar, renderData, histogramChannels());

    bindTimeGate(rootVar["TimeGate"]);
    mLaser.bindShaderData(rootVar["Laser_CB"]);
    mOptions.restir.bindShiftMapping(rootVar["Shiftmap_CB"]);

    mReSTIR.runSpatialReuse(pRenderContext, mpSpatialReusePass, var, mOptions.restir.spatialReuseIteration, mRandomSeed, frameDim);
}

void TransientHistogramReSTIRInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        mReSTIR.temporalHistoryValid = false;
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }

    if (!mpScene)
    {
        mReSTIR.temporalHistoryValid = false;
        InlinePass::clearChannels(pRenderContext, renderData, kOutputChannels);
        InlinePass::clearChannels(pRenderContext, renderData, histogramChannels());
        return;
    }

    if (mNeedToClearHistogram)
    {
        InlinePass::clearChannels(pRenderContext, renderData, histogramChannels());
        mNeedToClearHistogram = false;
    }

    // Temporal reuse assumes static geometry and light; only the camera may move.
    mLaser = LaserState::resolve(renderData);
    mReSTIR.invalidateHistory(*mpScene, mLaser != mPreviousLaser, false);

    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, getShaderDefines(renderData));
    if (!mpSpatialReusePass)
    {
        DefineList defines = getShaderDefines(renderData);
        defines.add("NEIGHBOR_OFFSET_COUNT", std::to_string(PathLengthAwareReSTIRResources::kNeighborOffsetCount));
        mpSpatialReusePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kSpatialReuseFile, defines);
    }
    const uint2 frameDim = renderData.getDefaultTextureDims();
    mReSTIR.prepare(mpDevice, mpScene, kReflectTypesFile, getReservoirDefines(), mOptions.histogram.timeBin, frameDim,
        mOptions.restir.useTemporalReuse, renderData.getTexture("vbuffer")->getFormat());

    InlinePass::checkScene(*mpScene, renderData, kInputViewDir);
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    mpComputePass->getProgram()->addDefines(getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    mpComputePass->execute(pRenderContext, uint3(frameDim, 1));

    spatialReuse(pRenderContext, renderData);
    mFrameCount++;

    mOptions.histogram.publishRange(renderData);

    // The final reservoirs become next frame's temporal history.
    mReSTIR.endFrame(pRenderContext, mOptions.restir.useTemporalReuse, *mpScene, renderData.getTexture("vbuffer"));
    mPreviousLaser = mLaser;
}

void TransientHistogramReSTIRInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    const uint previousBins = mOptions.histogram.timeBin;
    const bool previousSingleChannel = mOptions.pathTracing.useSingleChannel;

    if (auto group = widget.group("Histogram", true))
        dirty |= mOptions.histogram.renderUI(group, false);

    if (auto group = widget.group("Initial sampling", true))
        dirty |= mOptions.pathTracing.renderSamplingUI(group, " Each vertex is connected to the laser spot.");

    if (auto group = widget.group("Reuse", true))
    {
        dirty |= mOptions.restir.renderReuseUI(group, " Static scene and light; the camera may move.");

        dirty |= group.checkbox("Reuse adjacent bins", mOptions.useBinReuse);
        group.tooltip("Each spatial reuse iteration also resamples bins j-1 and j+1 of the same pixel.", true);
    }

    if (auto group = widget.group("Shift mapping", true))
        dirty |= mOptions.restir.renderShiftMappingUI(group);

    if (auto group = widget.group("Output", true))
        dirty |= mOptions.pathTracing.renderOutputUI(group, true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
        // The histogram texture depends on the bin count and channel count.
        if (mOptions.histogram.timeBin != previousBins || mOptions.pathTracing.useSingleChannel != previousSingleChannel)
            requestRecompile();
    }
}

void TransientHistogramReSTIRInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // The programs and the reservoir type depend on the scene.
    mpComputePass = nullptr;
    mpSpatialReusePass = nullptr;
    mReSTIR.resetScene();
    mFrameCount = 0;
    mpScene = pScene;
}
