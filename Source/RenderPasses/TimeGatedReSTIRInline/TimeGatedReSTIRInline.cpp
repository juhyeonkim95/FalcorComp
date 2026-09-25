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
    // pass.def_property("m", &MinimalTimeGatedPathTracer::isEnabled, &MinimalTimeGatedPathTracer::setEnabled);
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
const char kReflectTypesFile[] = "RenderPasses/TimeGatedReSTIRInline/ReflectTypes.cs.slang";
const char kSpatialReuseFile[] = "RenderPasses/TimeGatedReSTIRInline/SpatialReuse.cs.slang";
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

const ChannelList kDebugOutputChannels = {
    { "newtonStatistics", "gNewtonStatistics", "Mapping successes, actual successes, attempts, iteration sum", false, ResourceFormat::RGBA32Uint },
    { "mappingDistance", "gMappingDistance", "Sum of coordinate and world displacement for successful solves", false, ResourceFormat::RG32Float },
};

const char kRandomSeed[] = "randomSeed";
const char kIsSceneDynamic[] = "isSceneDynamic";
const char kDebugNewtonIterations[] = "debugNewtonIterations";
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
        else if (key == kTimeGateWindowRough)
            mOptions.timeGateWindowRough = value;
        else if (key == kRoughTimeGateSampleRatio)
            mOptions.roughTimeGateSampleRatio = value;
        else
            logWarning("Unknown property '{}' in TimeGatedReSTIRInline properties.", key);
    }
    mOptions.timeGate.applyTimeCenter(props);
    if (mOptions.ellipsoidalSampling.samplingMethod != EllipsoidalSamplingMethod::DIRECT &&
        mOptions.ellipsoidalSampling.triSampler != EmissiveLightSamplerType::Uniform && mOptions.ellipsoidalSampling.triSampler != EmissiveLightSamplerType::LightBVH)
        FALCOR_THROW("Ellipsoidal initial sampling requires the Uniform or LightBVH triangle sampler.");
    // Dynamic suffix replay reconstructs BSDF steps after y only. An ellipsoidal candidate
    // inserts x or y (both reevaluated exactly); inserting a vertex after y needs a walk
    // that reaches y and continues, i.e. maxBounces >= 4.
    if (mOptions.isSceneDynamic && mOptions.ellipsoidalSampling.samplingMethod != EllipsoidalSamplingMethod::DIRECT && mOptions.pathTracing.maxBounces > 3)
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
    props[kTimeGateWindowRough] = mOptions.timeGateWindowRough;
    props[kRoughTimeGateSampleRatio] = mOptions.roughTimeGateSampleRatio;
    return props;
}

RenderPassReflection TimeGatedReSTIRInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassInputs(reflector, kLaserInputChannels, ResourceBindFlags::ShaderResource, uint2(1, 1));
    addRenderPassInputs(reflector, kLaserHitInputChannels, ResourceBindFlags::ShaderResource, mOptions.restir.laserHitVBufferRes);
    addRenderPassOutputs(reflector, kOutputChannels);
    if (mOptions.debugNewtonIterations) addRenderPassOutputs(reflector, kDebugOutputChannels);

    return reflector;
}

DefineList TimeGatedReSTIRInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(LaserState::resolve(renderData).getDefines());
    defines.add(InlinePass::getSceneLightDefines(*mpScene));
    defines.add(mOptions.restir.getDefines());

    // Specialize away the entire extra reservoir/shift path when it has no samples.
    uint32_t wideSampleCount = 0;
    if (mOptions.ellipsoidalSampling.samplingMethod == EllipsoidalSamplingMethod::DIRECT && mOptions.pathTracing.samplesPerPixel > 0 &&
        std::isfinite(mOptions.timeGateWindowRough) && mOptions.timeGate.timeGateWindow > 0.f &&
        mOptions.timeGateWindowRough > mOptions.timeGate.timeGateWindow && std::isfinite(mOptions.roughTimeGateSampleRatio) &&
        (mOptions.timeGate.timeGateMode == TimeGateMode::BOX || mOptions.timeGate.timeGateMode == TimeGateMode::TENT))
    {
        const float ratio = std::clamp(mOptions.roughTimeGateSampleRatio, 0.f, 1.f);
        wideSampleCount = std::min(uint32_t(float(mOptions.pathTracing.samplesPerPixel) * ratio), mOptions.pathTracing.samplesPerPixel);
    }
    defines.add("USE_SHRINK_MAPPING", wideSampleCount > 0 ? "1" : "0");
    defines.add("SHRINK_WIDE_SAMPLE_COUNT", std::to_string(wideSampleCount));
    defines.add("DEBUG_NEWTON_ITERATIONS", mOptions.debugNewtonIterations ? "1" : "0");
    defines.add("IS_SCENE_DYNAMIC", mOptions.isSceneDynamic ? "1" : "0");

    defines.add("LIGHT_SAMPLING_METHOD", std::to_string((uint32_t)mOptions.ellipsoidalSampling.samplingMethod));
    defines.add("DIRECT_CONNECTION", std::to_string((uint32_t)EllipsoidalSamplingMethod::DIRECT));
    defines.add("ELLIPSOIDAL_CONNECTION", std::to_string((uint32_t)EllipsoidalSamplingMethod::ELLIPSOIDAL));
    defines.add("ELLIPSOIDAL_DIRECT_MIS", std::to_string((uint32_t)EllipsoidalSamplingMethod::ELLIPSOIDAL_DIRECT_MIS));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserInputChannels, renderData));
    defines.add(getValidResourceDefines(kLaserHitInputChannels, renderData));
    defines.add(getValidResourceDefines(kOutputChannels, renderData));
    return defines;
}

DefineList TimeGatedReSTIRInline::getReservoirDefines() const
{
    // The reservoir layout depends on these (see ReflectTypes.cs.slang).
    DefineList defines = mpScene->getSceneDefines();
    defines.add(mpSampleGenerator->getDefines());
    defines.add("IS_SCENE_DYNAMIC", mOptions.isSceneDynamic ? "1" : "0");
    defines.add("USE_SINGLE_CHANNEL", mOptions.pathTracing.useSingleChannel ? "1" : "0");
    defines.add("USE_IMPORTANCE_SAMPLING", mOptions.pathTracing.useImportanceSampling ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mOptions.pathTracing.useAlphaTest ? "1" : "0");
    defines.add(mLaser.getDefines());
    return defines;
}

void TimeGatedReSTIRInline::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    mTriangleSampler.bindShaderData(var["emissiveSampler"]);
    var["prevReservoirs"] = mReSTIR.prevReservoirs;
    var["currReservoirs"] = mReSTIR.currReservoirs;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gRandomSeed"] = mRandomSeed;
    var["CB"]["gFrameDim"] = renderData.getDefaultTextureDims();
    var["CB"]["gPRNGDimension"] = InlinePass::getPRNGDimension(renderData);
    var["CB"]["gLaserHitVBufferRes"] = mOptions.restir.laserHitVBufferRes;
    var["CB"]["specularRoughnessThreshold"] = mOptions.restir.reconnectionRoughnessThreshold;
    var["CB"]["specularRoughnessThresholdEllipsoid"] = mOptions.ellipsoidalSampling.ellipsoidRoughnessThreshold;
    var["CB"]["samplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gTemporalHistoryLength"] = mOptions.restir.temporalHistoryLength;
    var["CB"]["gRoughTimeGateSampleRatio"] = mOptions.roughTimeGateSampleRatio;

    mLaser.bindShaderData(var["Laser_CB"]);
    var["Laser_CB"]["laserPrevOrigin"] = mPreviousLaser.origin;
    var["Laser_CB"]["laserPrevDirection"] = mPreviousLaser.direction;

    mOptions.timeGate.bindShaderData(var["TimeGate"], mGate);
    var["TimeGate"]["time_gate_window_rough"] = mOptions.timeGateWindowRough;
    mOptions.restir.bindShiftMapping(var["Shiftmap_CB"]);

    InlinePass::bindChannels(var, renderData, kInputChannels);
    InlinePass::bindChannels(var, renderData, kLaserInputChannels);
    InlinePass::bindChannels(var, renderData, kLaserHitInputChannels);
    InlinePass::bindChannels(var, renderData, kOutputChannels);

    if (mOptions.restir.useTemporalReuse)
    {
        var["gTemporalVBuffer"] = mReSTIR.temporalVBuffer;
        var["CB"]["gTemporalHistoryValid"] = mReSTIR.temporalHistoryValid;
        var["CB"]["gPreviousCameraPosition"] = mReSTIR.previousCameraPosition;
        if (mOptions.isSceneDynamic)
        {
            var["Laser_CB"]["laserPrevPower"] = mPreviousLaser.power;
            var["Laser_CB"]["laserPrevCosAngle"] = mPreviousLaser.cosAngle;
        }
    }
}

void TimeGatedReSTIRInline::spatialReuse(RenderContext* pRenderContext, const RenderData& renderData)
{
    mpSpatialReusePass->getProgram()->addDefines(getShaderDefines(renderData));
    auto rootVar = mpSpatialReusePass->getRootVar();
    auto var = rootVar["CB"]["gSpatialReuse"];
    const uint2 frameDim = renderData.getDefaultTextureDims();

    mTriangleSampler.bindShaderData(rootVar["Shiftmap_CB"]["emissiveSamplerShiftmap"]);
    var["gFrameCount"] = mFrameCount;
    var["gFrameDim"] = frameDim;
    var["neighborOffsets"] = mReSTIR.neighborOffsets;
    var["useBinReuse"] = false; // A time gate has a single bin.
    mOptions.restir.bindSpatialReuse(var);

    InlinePass::bindChannels(var, renderData, kInputChannels);
    InlinePass::bindChannels(var, renderData, kLaserInputChannels);
    InlinePass::bindChannels(var, renderData, kOutputChannels);
    if (mOptions.debugNewtonIterations)
        InlinePass::bindChannels(var, renderData, kDebugOutputChannels);

    mOptions.timeGate.bindShaderData(rootVar["TimeGate"], mGate);
    rootVar["TimeGate"]["time_gate_window_rough"] = mOptions.timeGateWindowRough;
    mLaser.bindShaderData(rootVar["Laser_CB"]);
    mOptions.restir.bindShiftMapping(rootVar["Shiftmap_CB"]);

    // Clear diagnostics once per frame; spatial iterations add to these buffers.
    // Keep initial RGB intact, including when spatial iteration count is zero.
    if (mOptions.debugNewtonIterations)
    {
        pRenderContext->clearUAV(renderData.getTexture("newtonStatistics")->getUAV().get(), uint4(0));
        pRenderContext->clearUAV(renderData.getTexture("mappingDistance")->getUAV().get(), float4(0.f));
    }

    mReSTIR.runSpatialReuse(pRenderContext, mpSpatialReusePass, var, mOptions.restir.spatialReuseIteration, mRandomSeed, frameDim);
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
        InlinePass::clearChannels(pRenderContext, renderData, kOutputChannels);
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
    const uint2 frameDim = renderData.getDefaultTextureDims();
    mReSTIR.prepare(mpDevice, mpScene, kReflectTypesFile, getReservoirDefines(), 1, frameDim,
        mOptions.restir.useTemporalReuse, renderData.getTexture("vbuffer")->getFormat());

    InlinePass::checkScene(*mpScene, renderData, kInputViewDir);
    if (mpScene->getRenderSettings().useEmissiveLights)
        mpScene->getLightCollection(pRenderContext);

    mOptions.timeGate.beginFrame(mGate);
    mpComputePass->getProgram()->addDefines(getShaderDefines(renderData));
    bindShaderData(mpComputePass->getRootVar(), renderData);
    mpComputePass->execute(pRenderContext, uint3(frameDim, 1));

    spatialReuse(pRenderContext, renderData);
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

        if (mOptions.ellipsoidalSampling.samplingMethod == EllipsoidalSamplingMethod::DIRECT)
        {
            dirty |= group.var("Wide gate window", mOptions.timeGateWindowRough, 0.f, 1000.0f);
            group.tooltip("Direct sampling with a Box or Tent gate only: when wider than Gate window, a fraction of "
                          "the paths is traced with this wider gate and shrunk into the gate by the path-length "
                          "shift. 0 disables it.", true);
            dirty |= group.var("Wide gate path fraction", mOptions.roughTimeGateSampleRatio, 0.f, 1.f);
            group.tooltip("Fraction of the paths per pixel traced with the wide gate.", true);
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
        dirty |= mOptions.pathTracing.renderOutputUI(group, false);

    if (dirty)
    {
        mUIWarning.clear();
        // Same constraint as parseProperties(): see the comment there.
        if (mOptions.isSceneDynamic && mOptions.ellipsoidalSampling.samplingMethod != EllipsoidalSamplingMethod::DIRECT && mOptions.pathTracing.maxBounces > 3)
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
    mTriangleSampler.reset();
    mReSTIR.resetScene();
    mFrameCount = 0;
    mpScene = pScene;
}
