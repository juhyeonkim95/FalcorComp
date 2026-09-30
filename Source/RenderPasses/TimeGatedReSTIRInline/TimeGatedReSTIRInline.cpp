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
#include "TimeGatedReSTIRInline.h"
#include <algorithm>
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regTimeGatedReSTIRInline(pybind11::module& m)
{
    pybind11::class_<TimeGatedReSTIRInline, RenderPass, ref<TimeGatedReSTIRInline>> pass(m, "TimeGatedReSTIRInline");
    pass.def("increment_time_gate_frame", &TimeGatedReSTIRInline::incrementTimeGateFrame);
    pass.def("set_time_gate_info", &TimeGatedReSTIRInline::setTimeGateInfo);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TimeGatedReSTIRInline>();
    ScriptBindings::registerBinding(regTimeGatedReSTIRInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TimeGatedReSTIRInline/InitialSampleGeneration.cs.slang";
const char kSpatialReuseFile[] = "RenderPasses/TimeGatedReSTIRInline/SpatialReuse.cs.slang";
const char kSpatialReusePairsFile[] = "RenderPasses/TimeGatedReSTIRInline/SpatialReusePairs.cs.slang";
const char kAddDirectFile[] = "RenderPasses/TimeGatedReSTIRInline/AddDirect.cs.slang";

const ChannelList kDebugOutputChannels = {
    { "newtonStatistics", "gNewtonStatistics", "Mapping successes, actual successes, attempts, iteration sum", false, ResourceFormat::RGBA32Uint },
    { "mappingDistance", "gMappingDistance", "Sum of coordinate and world displacement for successful solves", false, ResourceFormat::RG32Float },
};

const char kRandomSeed[] = "randomSeed";
const char kIsSceneDynamic[] = "isSceneDynamic";
const char kDebugNewtonIterations[] = "debugNewtonIterations";
const char kUseShrinkMapping[] = "useShrinkMapping";
const char kTimeGateWindowRough[] = "timeGateWindowRough";
const char kRoughTimeGateSampleRatio[] = "roughTimeGateSampleRatio";
} // namespace

TimeGatedReSTIRInline::TimeGatedReSTIRInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void TimeGatedReSTIRInline::incrementTimeGateFrame()
{
    mGate.advance();
}

void TimeGatedReSTIRInline::setTimeGateInfo(float timeMin, float timeMax, uint timeBin)
{
    mOptions.timeGate.timeMin = timeMin;
    mOptions.timeGate.timeMax = timeMax;
    mOptions.timeGate.timeBin = timeBin;
}

void TimeGatedReSTIRInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.timeGate.parse(key, value) || mOptions.ellipsoidalSampling.parse(key, value) ||
            mOptions.pathTracing.parse(key, value) || mOptions.restir.parse(key, value))
            continue;
        if (key == kRandomSeed)
            mRandomSeed = value;
        else if (key == kIsSceneDynamic)
            mOptions.isSceneDynamic = value;
        else if (key == kDebugNewtonIterations)
            mOptions.debugNewtonIterations = value;
        else if (key == kUseShrinkMapping)
            mOptions.useShrinkMapping = value;
        else if (key == kTimeGateWindowRough)
            mOptions.timeGateWindowRough = value;
        else if (key == kRoughTimeGateSampleRatio)
            mOptions.roughTimeGateSampleRatio = value;
        else
            logWarning("Unknown property '{}' in TimeGatedReSTIRInline properties.", key);
    }
    mOptions.timeGate.applyTimeCenter(props);
    if (mOptions.ellipsoidalSampling.samplingMethod != EllipsoidalSamplingMethod::Direct &&
        mOptions.ellipsoidalSampling.triSampler != EmissiveLightSamplerType::Uniform && mOptions.ellipsoidalSampling.triSampler != EmissiveLightSamplerType::LightBVH)
        FALCOR_THROW("Ellipsoidal initial sampling requires the Uniform or LightBVH triangle sampler.");
    // Dynamic suffix replay reconstructs BSDF steps after y only. An ellipsoidal candidate
    // inserts x or y (both reevaluated exactly); inserting a vertex after y needs a walk
    // that reaches y and continues, i.e. maxBounces >= 4.
    if (mOptions.isSceneDynamic && mOptions.ellipsoidalSampling.samplingMethod != EllipsoidalSamplingMethod::Direct && mOptions.pathTracing.maxBounces > 3)
        FALCOR_THROW("Ellipsoidal initial sampling with isSceneDynamic=true requires maxBounces <= 3.");
}

Properties TimeGatedReSTIRInline::getProperties() const
{
    Properties props;
    mOptions.timeGate.serialize(props);
    mOptions.ellipsoidalSampling.serialize(props);
    mOptions.pathTracing.serialize(props);
    mOptions.restir.serialize(props);
    props[kRandomSeed] = mRandomSeed;
    props[kIsSceneDynamic] = mOptions.isSceneDynamic;
    props[kDebugNewtonIterations] = mOptions.debugNewtonIterations;
    props[kUseShrinkMapping] = mOptions.useShrinkMapping;
    props[kTimeGateWindowRough] = mOptions.timeGateWindowRough;
    props[kRoughTimeGateSampleRatio] = mOptions.roughTimeGateSampleRatio;
    return props;
}

void TimeGatedReSTIRInline::setProperties(const Properties& props)
{
    const auto previousSamplingMethod = mOptions.ellipsoidalSampling.samplingMethod;
    const auto previousTriSampler = mOptions.ellipsoidalSampling.triSampler;
    parseProperties(props);
    // Same rebuilds as a UI edit: the emissive sampler's defines are only added when the programs are created.
    if (mOptions.ellipsoidalSampling.triSampler != previousTriSampler)
        mTriangleSampler.reset();
    if (mOptions.ellipsoidalSampling.samplingMethod != previousSamplingMethod || mOptions.ellipsoidalSampling.triSampler != previousTriSampler)
    {
        mpComputePass = nullptr;
        mpSpatialReusePass = nullptr;
        mpSpatialReusePairsPass = nullptr;
    }
    mOptionsChanged = true;
}

RenderPassReflection TimeGatedReSTIRInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, InlinePass::kPrimaryHitAndMotionInputChannels);
    addRenderPassOutputs(reflector, InlinePass::kColorOutputChannels);
    if (mOptions.debugNewtonIterations) addRenderPassOutputs(reflector, kDebugOutputChannels);

    return reflector;
}

DefineList TimeGatedReSTIRInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(LaserState::resolve(renderData).getDefines());
    defines.add(InlinePass::getSceneLightDefines(*mpScene));
    defines.add(mOptions.restir.getDefines());

    // Specialize away the entire extra reservoir/shift path when it has no samples. The shader computes the
    // same count from gRoughTimeGateSampleRatio, so changing the ratio or samplesPerPixel does not recompile.
    uint32_t wideSampleCount = 0;
    if (mOptions.useShrinkMapping && mOptions.ellipsoidalSampling.samplingMethod == EllipsoidalSamplingMethod::Direct &&
        mOptions.pathTracing.samplesPerPixel > 0 && std::isfinite(mOptions.wideGateWindow()) &&
        mOptions.timeGate.timeGateWindow > 0.f && mOptions.wideGateWindow() > mOptions.timeGate.timeGateWindow &&
        std::isfinite(mOptions.roughTimeGateSampleRatio) &&
        (mOptions.timeGate.timeGateMode == TimeGateMode::Box || mOptions.timeGate.timeGateMode == TimeGateMode::Tent))
    {
        wideSampleCount = std::min(uint32_t(float(mOptions.pathTracing.samplesPerPixel) * shrinkSampleRatio()),
                                   mOptions.pathTracing.samplesPerPixel);
    }
    defines.add("USE_SHRINK_MAPPING", wideSampleCount > 0 ? "1" : "0");
    defines.add("DEBUG_NEWTON_ITERATIONS", mOptions.debugNewtonIterations ? "1" : "0");
    defines.add("SPATIAL_REUSE_PAIRS", useSpatialReusePairs() ? "1" : "0");
    defines.add(PathLengthAwareReSTIRResources::getReservoirDefines(mOptions.pathTracing, mOptions.isSceneDynamic));

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.ellipsoidalSampling.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)EllipsoidalSamplingMethod::Direct));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)EllipsoidalSamplingMethod::Ellipsoidal));
    defines.add("ELLIPSOIDAL_DIRECT_MIS", std::to_string((uint32_t)EllipsoidalSamplingMethod::EllipsoidalDirectMIS));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(InlinePass::kPrimaryHitAndMotionInputChannels, renderData));
    defines.add(getValidResourceDefines(InlinePass::kColorOutputChannels, renderData));
    return defines;
}

void TimeGatedReSTIRInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    mTriangleSampler.bindShaderData(var["emissiveSampler"]);
    var["gPrevReservoirs"] = mReSTIR.prevReservoirs;
    var["gCurrReservoirs"] = mReSTIR.currReservoirs;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gReconnectionRoughnessThreshold"] = mOptions.restir.reconnectionRoughnessThreshold;
    var["CB"]["gReconnectionMinDistance"] = mOptions.restir.reconnectionMinDistance;
    var["CB"]["gEllipsoidRoughnessThreshold"] = mOptions.ellipsoidalSampling.ellipsoidRoughnessThreshold;
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gTemporalHistoryLength"] = mOptions.restir.temporalHistoryLength;
    var["CB"]["gRoughTimeGateSampleRatio"] = shrinkSampleRatio();

    mLaser.bindShaderData(var["Laser"]);

    mOptions.timeGate.bindShaderData(var["TimeGate"], mGate);
    var["TimeGate"]["gTimeGateWindowRough"] = mOptions.wideGateWindow();
    mOptions.restir.bindShiftMapping(var["ShiftMappingCB"]);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitAndMotionInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
    if (mOptions.pathTracing.computeDirect)
        var["gDirectColor"] = mpDirectColor;

    if (mOptions.restir.useTemporalReuse)
    {
        var["gTemporalVBuffer"] = mReSTIR.temporalVBuffer;
        var["CB"]["gTemporalHistoryValid"] = mReSTIR.temporalHistoryValid;
        var["CB"]["gPreviousCameraPosition"] = mReSTIR.previousCameraPosition;
        if (mOptions.isSceneDynamic)
        {
            var["PreviousLaser"]["gPreviousLaserOrigin"] = mPreviousLaser.origin;
            var["PreviousLaser"]["gPreviousLaserDirection"] = mPreviousLaser.direction;
            var["PreviousLaser"]["gPreviousLaserPower"] = mPreviousLaser.power;
            var["PreviousLaser"]["gPreviousLaserCosAngle"] = mPreviousLaser.cosAngle;
        }
    }
}

void TimeGatedReSTIRInline::bindSpatialReuse(const ref<ComputePass>& pass, const RenderData& renderData)
{
    auto rootVar = pass->getRootVar();
    auto var = rootVar["CB"]["gSpatialReuse"];
    const uint2 frameDim = renderData.getDefaultTextureDims();

    var["gFrameCount"] = mFrameCount;
    var["gFrameDim"] = frameDim;
    var["neighborOffsets"] = mReSTIR.neighborOffsets;
    var["useBinReuse"] = false; // A time gate has a single bin.
    mOptions.restir.bindSpatialReuse(var);

    InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitAndMotionInputChannels);
    InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
    if (mOptions.debugNewtonIterations)
        InlinePass::bindChannels(var, renderData, kDebugOutputChannels);

    mOptions.timeGate.bindShaderData(rootVar["TimeGate"], mGate);
    rootVar["TimeGate"]["gTimeGateWindowRough"] = mOptions.wideGateWindow();
    mLaser.bindShaderData(rootVar["Laser"]);
    mOptions.restir.bindShiftMapping(rootVar["ShiftMappingCB"]);
    if (useSpatialReusePairs())
        var["pairs"] = mpSpatialPairs;
}

void TimeGatedReSTIRInline::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
{
    const uint2 frameDim = renderData.getDefaultTextureDims();
    const DefineList defines = getShaderDefines(renderData);
    InlinePass::updateScenePassDefines(pRenderContext, mpSpatialReusePass, mpScene, mpSampleGenerator, defines);
    const uint candidateCount = mOptions.restir.spatialReuseNeighborCount;
    if (useSpatialReusePairs())
    {
        InlinePass::updateScenePassDefines(pRenderContext, mpSpatialReusePairsPass, mpScene, mpSampleGenerator, defines);
        const uint32_t pairCount = std::max(frameDim.x * frameDim.y * candidateCount, 1u);
        if (!mpSpatialPairs || mpSpatialPairs->getElementCount() != pairCount)
            mpSpatialPairs = mpDevice->createStructuredBuffer(
                mpSpatialReusePairsPass->getRootVar()["CB"]["gSpatialReuse"]["pairs"], pairCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr,
                false);
        bindSpatialReuse(mpSpatialReusePairsPass, renderData);
    }
    bindSpatialReuse(mpSpatialReusePass, renderData);

    // Clear diagnostics once per frame; spatial iterations add to these buffers.
    // Keep initial RGB intact, including when spatial iteration count is zero.
    if (mOptions.debugNewtonIterations)
    {
        pRenderContext->clearUAV(renderData.getTexture("newtonStatistics")->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(renderData.getTexture("mappingDistance")->getUAV().get(), float4(0.f));
    }

    auto var = mpSpatialReusePass->getRootVar()["CB"]["gSpatialReuse"];
    if (useSpatialReusePairs())
        mReSTIR.runSpatialReuse(pRenderContext, mpSpatialReusePairsPass,
            mpSpatialReusePairsPass->getRootVar()["CB"]["gSpatialReuse"], candidateCount, mpSpatialReusePass, var,
            mOptions.restir.spatialReuseIteration, mRandomSeed, frameDim);
    else
        mReSTIR.runSpatialReuse(pRenderContext, mpSpatialReusePass, var, mOptions.restir.spatialReuseIteration, mRandomSeed, frameDim);
}

void TimeGatedReSTIRInline::addDirect(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpAddDirectPass)
        mpAddDirectPass = ComputePass::create(mpDevice, kAddDirectFile, "main");
    const uint2 frameDim = renderData.getDefaultTextureDims();
    auto var = mpAddDirectPass->getRootVar();
    var["CB"]["gFrameDim"] = frameDim;
    var["gDirectColor"] = mpDirectColor;
    var["gOutputColor"] = renderData.getTexture("color");
    mpAddDirectPass->execute(pRenderContext, uint3(frameDim, 1));
}

void TimeGatedReSTIRInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        mReSTIR.temporalHistoryValid = false;
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }
    if (mGateMoved)
    {
        InlinePass::flagOptionsChanged(renderData);
        mGateMoved = false;
    }

    if (!mpScene)
    {
        mReSTIR.temporalHistoryValid = false;
        InlinePass::clearChannels(pRenderContext, renderData, InlinePass::kColorOutputChannels);
        if (mOptions.debugNewtonIterations)
            InlinePass::clearChannels(pRenderContext, renderData, kDebugOutputChannels);
        return;
    }

    // Dynamic mode supports moving cameras/lights, but not geometry or material changes.
    mLaser = LaserState::resolve(renderData);
    mReSTIR.invalidateHistory(*mpScene, mLaser != mPreviousLaser, mOptions.isSceneDynamic);

    mTriangleSampler.prepare(pRenderContext, mpScene, mOptions.ellipsoidalSampling);
    if (!mpComputePass)
    {
        DefineList defines = getShaderDefines(renderData);
        defines.add(mTriangleSampler.getDefines());
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, defines);
    }
    if (!mpSpatialReusePass)
    {
        DefineList defines = getShaderDefines(renderData);
        defines.add(mTriangleSampler.getDefines());
        defines.add("NEIGHBOR_OFFSET_COUNT", std::to_string(PathLengthAwareReSTIRResources::kNeighborOffsetCount));
        mpSpatialReusePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kSpatialReuseFile, defines);
    }
    if (useSpatialReusePairs() && !mpSpatialReusePairsPass)
    {
        DefineList defines = getShaderDefines(renderData);
        defines.add(mTriangleSampler.getDefines());
        defines.add("NEIGHBOR_OFFSET_COUNT", std::to_string(PathLengthAwareReSTIRResources::kNeighborOffsetCount));
        mpSpatialReusePairsPass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kSpatialReusePairsFile, defines);
    }
    const uint2 frameDim = renderData.getDefaultTextureDims();
    if (mOptions.pathTracing.computeDirect &&
        (!mpDirectColor || mpDirectColor->getWidth() != frameDim.x || mpDirectColor->getHeight() != frameDim.y))
    {
        mpDirectColor = mpDevice->createTexture2D(frameDim.x, frameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess);
    }
    else if (!mOptions.pathTracing.computeDirect)
        mpDirectColor = nullptr;
    mReSTIR.prepare(mpDevice, mpScene, mpSampleGenerator, mOptions.pathTracing, mOptions.isSceneDynamic, 1, frameDim,
        mOptions.restir.useTemporalReuse, renderData.getTexture("vbuffer")->getFormat());

    InlinePass::checkScene(*mpScene, renderData);
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    mOptions.timeGate.beginFrame(mGate);
    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator, getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    mpComputePass->execute(pRenderContext, uint3(frameDim, 1));

    spatialReuse(pRenderContext, renderData);
    // The primary-hit direct lighting is added after reuse; it never enters the reservoirs.
    if (mOptions.pathTracing.computeDirect)
        addDirect(pRenderContext, renderData);
    mFrameCount++;

    mReSTIR.endFrame(pRenderContext, mOptions.restir.useTemporalReuse, *mpScene, renderData.getTexture("vbuffer"));
    mPreviousLaser = mLaser;
    mGate.endFrame();

    // Temporal reuse maps the history from tprev to the new gate, so it stays valid.
    if (mOptions.timeGate.shiftGate && mOptions.timeGate.timeMax > mOptions.timeGate.timeMin)
    {
        incrementTimeGateFrame();
        mGateMoved = true;
    }
}

void TimeGatedReSTIRInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    // Settings validated together; a rejected edit restores them.
    const auto previousSamplingMethod = mOptions.ellipsoidalSampling.samplingMethod;
    const auto previousTriSampler = mOptions.ellipsoidalSampling.triSampler;
    const uint previousMaxBounces = mOptions.pathTracing.maxBounces;
    const bool previousSceneDynamic = mOptions.isSceneDynamic;

    if (auto group = widget.group("Time gate", true))
    {
        dirty |= mOptions.timeGate.renderUI(group, mGate.current,
            " Temporal reuse maps the history to each new gate.");
    }

    if (auto group = widget.group("Initial sampling", true))
    {
        dirty |= mOptions.pathTracing.renderSamplingUI(group, " The primary hit is not connected to the laser spot.");
        // Ellipsoidal initial sampling supports the Uniform and LightBVH triangle samplers only.
        dirty |= mOptions.ellipsoidalSampling.renderUI(group, false);

        if (mOptions.ellipsoidalSampling.samplingMethod == EllipsoidalSamplingMethod::Direct)
        {
            dirty |= group.checkbox("Shrink mapping", mOptions.useShrinkMapping);
            group.tooltip("Trace paths with a wider gate and shrink them into the gate with the path-length shift, "
                          "which finds more candidates for a narrow gate. Box or Tent gate only.", true);
            if (mOptions.useShrinkMapping)
            {
                float wideWindow = mOptions.wideGateWindow();
                if (group.var("Wide gate window", wideWindow, 0.f, 1000.0f))
                {
                    mOptions.timeGateWindowRough = wideWindow;
                    dirty = true;
                }
                group.tooltip("Width of the wider gate, in path-length units. Until set, 10 x Gate window.", true);
                dirty |= group.var("Wide gate path fraction", mOptions.roughTimeGateSampleRatio, 0.f, 1.f);
                group.tooltip("Fraction of the paths per pixel traced with the wide gate; the others use the gate "
                              "itself.", true);
                if (!(mOptions.wideGateWindow() > mOptions.timeGate.timeGateWindow))
                    group.text("Off: the wide gate must be wider than Gate window.");
                else if (mOptions.timeGate.timeGateMode != TimeGateMode::Box && mOptions.timeGate.timeGateMode != TimeGateMode::Tent)
                    group.text("Off: shrink mapping needs a Box or Tent gate.");
            }
        }
    }

    if (auto group = widget.group("Reuse", true))
    {
        dirty |= mOptions.restir.renderReuseUI(group, " Its paths are shifted from the previous gate to the current one.");

        dirty |= group.checkbox("Dynamic light", mOptions.isSceneDynamic);
        group.tooltip("Keep the temporal history when the laser moves or changes, re-evaluating the lighting of "
                      "reused paths. Off: any laser change discards the history. Geometry changes always discard "
                      "it.", true);
    }

    if (auto group = widget.group("Shift mapping", true))
        dirty |= mOptions.restir.renderShiftMappingUI(group);

    if (auto group = widget.group("Output", true))
        dirty |= mOptions.pathTracing.renderOutputUI(group, true, true);

    if (dirty)
    {
        mUIWarning.clear();
        // Same constraint as parseProperties(): see the comment there.
        if (mOptions.isSceneDynamic && mOptions.ellipsoidalSampling.samplingMethod != EllipsoidalSamplingMethod::Direct && mOptions.pathTracing.maxBounces > 3)
        {
            mUIWarning = "Ellipsoidal sampling with a dynamic light supports at most 3 bounces.";
            mOptions.ellipsoidalSampling.samplingMethod = previousSamplingMethod;
            mOptions.pathTracing.maxBounces = previousMaxBounces;
            mOptions.isSceneDynamic = previousSceneDynamic;
        }
        // Rebuild the sampler and programs: the emissive sampler's defines are only added when they are created.
        if (mOptions.ellipsoidalSampling.triSampler != previousTriSampler)
            mTriangleSampler.reset();
        if (mOptions.ellipsoidalSampling.samplingMethod != previousSamplingMethod || mOptions.ellipsoidalSampling.triSampler != previousTriSampler)
        {
            mpComputePass = nullptr;
            mpSpatialReusePass = nullptr;
            mpSpatialReusePairsPass = nullptr;
        }
        // Pass the flag to downstream passes (accumulation reset) and discard the ReSTIR history.
        mOptionsChanged = true;
    }
    if (!mUIWarning.empty())
        widget.text(mUIWarning);
}

void TimeGatedReSTIRInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // The programs, the triangle sampler and the reservoir type depend on the scene.
    mpComputePass = nullptr;
    mpSpatialReusePass = nullptr;
    mpSpatialReusePairsPass = nullptr;
    mTriangleSampler.reset();
    mReSTIR.resetScene();
    mFrameCount = 0;
    mpScene = pScene;
}
