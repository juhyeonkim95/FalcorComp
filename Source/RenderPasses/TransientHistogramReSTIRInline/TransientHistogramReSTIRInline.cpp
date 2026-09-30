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
const char kSpatialReuseFile[] = "RenderPasses/TransientHistogramReSTIRInline/SpatialReuse.cs.slang";
const char kSpatialReusePairsFile[] = "RenderPasses/TransientHistogramReSTIRInline/SpatialReusePairs.cs.slang";

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
const char kSkipEmptyReservoirs[] = "skipEmptyReservoirs";
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
        else if (key == kSkipEmptyReservoirs)
            mOptions.skipEmptyReservoirs = value;
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
    props[kSkipEmptyReservoirs] = mOptions.skipEmptyReservoirs;
    props[kRandomSeed] = mRandomSeed;
    return props;
}

RenderPassReflection TransientHistogramReSTIRInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitAndMotionInputChannels);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels);

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
    defines.add(PathLengthAwareReSTIRResources::getReservoirDefines(mOptions.pathTracing, false));
    defines.add("SPATIAL_REUSE_PAIRS", useSpatialReusePairs() ? "1" : "0");
    defines.add("RESERVOIR_SUMMARIES", mOptions.skipEmptyReservoirs ? "1" : "0");

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitAndMotionInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    defines.add(getValidResourceDefines(histogramChannels(), renderData));
    return defines;
}

const ChannelList& TransientHistogramReSTIRInline::histogramChannels() const
{
    return mOptions.pathTracing.useSingleChannel ? kHistogramOutputChannelSingle : kHistogramOutputChannelsRGB;
}

void TransientHistogramReSTIRInline::bindTimeGate(const ShaderVar& var) const
{
    // Each bin is a box gate one bin wide.
    mOptions.histogram.bindShaderData(var);
    var["TimeGate"]["gTimeGateWindow"] = mOptions.histogram.binWidth();
    var["TimeGate"]["gTimeGateWindowRough"] = mOptions.histogram.binWidth();
}

void TransientHistogramReSTIRInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    var["gPrevReservoirs"] = mReSTIR.prevReservoirs;
    var["gCurrReservoirs"] = mReSTIR.currReservoirs;
    if (mReSTIR.prevSummaries)
    {
        var["gPrevSummaries"] = mReSTIR.prevSummaries;
        var["gCurrSummaries"] = mReSTIR.currSummaries;
    }

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gReconnectionRoughnessThreshold"] = mOptions.restir.reconnectionRoughnessThreshold;
    var["CB"]["gReconnectionMinDistance"] = mOptions.restir.reconnectionMinDistance;
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gTemporalHistoryLength"] = mOptions.restir.temporalHistoryLength;
    mLaser.bindShaderData(var["Laser"]);
    bindTimeGate(var);

    if (mOptions.restir.useTemporalReuse)
    {
        // Temporal reuse shifts last frame's paths in this pass.
        var["gTemporalVBuffer"] = mReSTIR.temporalVBuffer;
        var["CB"]["gTemporalHistoryValid"] = mReSTIR.temporalHistoryValid;
        var["CB"]["gPreviousCameraPosition"] = mReSTIR.previousCameraPosition;
        mOptions.restir.bindShiftMapping(var["ShiftMappingCB"]);
    }

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitAndMotionInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
    InlinePass::bindChannels(var, renderData, histogramChannels());
}

void TransientHistogramReSTIRInline::bindSpatialReuse(const ref<ComputePass>& pass, const RenderData& renderData)
{
    auto rootVar = pass->getRootVar();
    auto var = rootVar["CB"]["gSpatialReuse"];
    const uint2 frameDim = renderData.getDefaultTextureDims();

    var["gFrameCount"] = mFrameCount;
    var["gFrameDim"] = frameDim;
    var["neighborOffsets"] = mReSTIR.neighborOffsets;
    var["useBinReuse"] = mOptions.useBinReuse;
    mOptions.restir.bindSpatialReuse(var);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitAndMotionInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
    // The histogram is a pass-level global, outside the shared SpatialReuse struct; only the resampling pass writes it.
    if (pass == mpSpatialReusePass)
        InlinePass::bindChannels(rootVar, renderData, histogramChannels());

    bindTimeGate(rootVar);
    mLaser.bindShaderData(rootVar["Laser"]);
    mOptions.restir.bindShiftMapping(rootVar["ShiftMappingCB"]);
    if (useSpatialReusePairs())
    {
        var["pairs"] = mReSTIR.spatialPairs;
        var["pairCandidateValid"] = mReSTIR.spatialCandidateValid;
    }
}

void TransientHistogramReSTIRInline::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
{
    const uint2 frameDim = renderData.getDefaultTextureDims();
    const DefineList defines = getShaderDefines(renderData);
    InlinePass::updateScenePassDefines(pRenderContext, mpSpatialReusePass, mpScene, mpSampleGenerator, defines);
    const uint candidateCount = mOptions.restir.spatialReuseNeighborCount + (mOptions.useBinReuse ? 2 : 0);
    const uint binCount = mOptions.histogram.timeBin;
    uint chunkBins = binCount;
    if (useSpatialReusePairs())
    {
        InlinePass::updateScenePassDefines(pRenderContext, mpSpatialReusePairsPass, mpScene, mpSampleGenerator, defines);
        chunkBins = mReSTIR.preparePairs(mpDevice, mpSpatialReusePairsPass->getRootVar()["CB"]["gSpatialReuse"],
            frameDim, candidateCount, mOptions.restir.spatialReuseNeighborCount, binCount);
        bindSpatialReuse(mpSpatialReusePairsPass, renderData);
    }
    bindSpatialReuse(mpSpatialReusePass, renderData);

    auto var = mpSpatialReusePass->getRootVar()["CB"]["gSpatialReuse"];
    if (useSpatialReusePairs())
        mReSTIR.runSpatialReuse(pRenderContext, mpSpatialReusePairsPass,
            mpSpatialReusePairsPass->getRootVar()["CB"]["gSpatialReuse"], candidateCount, mpSpatialReusePass, var,
            mOptions.restir.spatialReuseIteration, mRandomSeed, frameDim, binCount, chunkBins);
    else
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
        InlinePass::clearChannels(pRenderContext, renderData, InlinePass::kColorOutputChannels);
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
    if (useSpatialReusePairs() && !mpSpatialReusePairsPass)
    {
        DefineList defines = getShaderDefines(renderData);
        defines.add("NEIGHBOR_OFFSET_COUNT", std::to_string(PathLengthAwareReSTIRResources::kNeighborOffsetCount));
        mpSpatialReusePairsPass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kSpatialReusePairsFile, defines);
    }
    const uint2 frameDim = renderData.getDefaultTextureDims();
    mReSTIR.prepare(mpDevice, mpScene, mpSampleGenerator, mOptions.pathTracing, false, mOptions.histogram.timeBin, frameDim,
        mOptions.restir.useTemporalReuse, renderData.getTexture("vbuffer")->getFormat(), mOptions.skipEmptyReservoirs);

    InlinePass::checkScene(*mpScene, renderData);
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator, getShaderDefines(renderData));
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

        dirty |= group.checkbox("Skip empty reservoirs", mOptions.skipEmptyReservoirs);
        group.tooltip("Store only the reservoirs of bins holding a sample, plus every bin's W and M in a small buffer. "
                      "Faster while most bins are empty (initial sampling, first spatial iteration); little gain once "
                      "temporal or repeated spatial reuse fills the bins. The results are the same.", true);
    }

    if (auto group = widget.group("Shift mapping", true))
        dirty |= mOptions.restir.renderShiftMappingUI(group);

    if (auto group = widget.group("Output", true))
        dirty |= mOptions.pathTracing.renderOutputUI(group, true, true);

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
    mpSpatialReusePairsPass = nullptr;
    mReSTIR.resetScene();
    mFrameCount = 0;
    mpScene = pScene;
}
