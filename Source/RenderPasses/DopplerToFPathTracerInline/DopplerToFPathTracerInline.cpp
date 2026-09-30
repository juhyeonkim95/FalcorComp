/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
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
#include "DopplerToFPathTracerInline.h"
#include <cmath>
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

static void regDopplerToFPathTracerInline(pybind11::module& m)
{
    using namespace pybind11::literals;
    pybind11::class_<DopplerToFPathTracerInline, RenderPass, ref<DopplerToFPathTracerInline>> pass(
        m, "DopplerToFPathTracerInline");
    pass.def("set_velocity", &DopplerToFPathTracerInline::setVelocity, "name"_a, "linear"_a,
        "angular"_a = float3(0.f), "center"_a = float3(0.f));
    pass.def("reset_sequence", &DopplerToFPathTracerInline::resetSequence);
    pass.def("get_object_names", &DopplerToFPathTracerInline::getObjectNames);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, DopplerToFPathTracerInline>();
    ScriptBindings::registerBinding(regDopplerToFPathTracerInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/DopplerToFPathTracerInline/DopplerToFPathTracerInline.cs.slang";

const ChannelList kOutputChannels = {
    { "color", "gOutputColor", "Doppler ToF measurement (signed)", false, ResourceFormat::RGBA32Float },
};

const char kModulationFrequency[] = "modulationFrequency";
const char kHeterodyneFrequency[] = "heterodyneFrequency";
const char kExposureTime[] = "exposureTime";
const char kPhase[] = "phase";
const char kTimeSampling[] = "timeSampling";
const char kAntithetic[] = "antithetic";
const char kVelocities[] = "velocities";
const char kSeed[] = "seed";

const std::map<std::string, DopplerToFPathTracerInline::TimeSampling> kTimeSamplings = {
    {"uniform", DopplerToFPathTracerInline::TimeSampling::Uniform},
    {"stratified", DopplerToFPathTracerInline::TimeSampling::Stratified},
};
const std::map<std::string, DopplerToFPathTracerInline::Antithetic> kAntithetics = {
    {"none", DopplerToFPathTracerInline::Antithetic::None},
    {"half_period", DopplerToFPathTracerInline::Antithetic::HalfPeriod},
    {"mirror", DopplerToFPathTracerInline::Antithetic::Mirror},
};

template<typename T>
T parseName(const std::map<std::string, T>& table, const std::string& value, const char* key)
{
    auto it = table.find(value);
    if (it == table.end())
        FALCOR_THROW("Unknown value '{}' for {}.", value, key);
    return it->second;
}

template<typename T>
std::string nameOf(const std::map<std::string, T>& table, T value)
{
    for (const auto& [name, v] : table)
        if (v == value)
            return name;
    return "";
}
} // namespace

DopplerToFPathTracerInline::DopplerToFPathTracerInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
}

void DopplerToFPathTracerInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (mOptions.pathTracing.parse(key, value))
            continue;
        if (key == kModulationFrequency)
            mOptions.modulationFrequency = value;
        else if (key == kHeterodyneFrequency)
            mOptions.heterodyneFrequency = value;
        else if (key == kExposureTime)
            mOptions.exposureTime = value;
        else if (key == kPhase)
            mOptions.phase = value;
        else if (key == kTimeSampling)
            mOptions.timeSampling = parseName(kTimeSamplings, std::string(value), kTimeSampling);
        else if (key == kAntithetic)
            mOptions.antithetic = parseName(kAntithetics, std::string(value), kAntithetic);
        else if (key == kSeed)
            mOptions.seed = value;
        else if (key == kVelocities)
        {
            // {"object name": {"linear": [..], "angular": [..], "center": [..]}}; missing entries are zero.
            const Properties objects = value;
            mOptions.velocities.clear();
            for (const auto& [name, motionValue] : objects)
            {
                const Properties motionProps = motionValue;
                Motion motion;
                motion.linear = motionProps.get<float3>("linear", float3(0.f));
                motion.angular = motionProps.get<float3>("angular", float3(0.f));
                motion.center = motionProps.get<float3>("center", float3(0.f));
                mOptions.velocities[name] = motion;
            }
        }
        else
            logWarning("Unknown property '{}' in DopplerToFPathTracerInline properties.", key);
    }
}

void DopplerToFPathTracerInline::validateOptions(const Options& options)
{
    options.pathTracing.validate();
    if (!(options.modulationFrequency > 0.f) || !(options.exposureTime > 0.f))
        FALCOR_THROW("modulationFrequency and exposureTime must be positive.");
    if (options.antithetic == Antithetic::HalfPeriod && !(options.heterodyneFrequency != 0.f))
        FALCOR_THROW("The half_period antithetic pairing needs a nonzero heterodyneFrequency.");
    const double periods = double(options.exposureTime) * options.heterodyneFrequency;
    if (std::abs(periods - std::round(periods)) > 1e-3)
        logWarning("DopplerToFPathTracerInline: exposureTime x heterodyneFrequency = {} is not an integer: static "
                   "objects do not cancel.", periods);
}

Properties DopplerToFPathTracerInline::getProperties() const
{
    Properties props;
    mOptions.pathTracing.serialize(props);
    props[kModulationFrequency] = mOptions.modulationFrequency;
    props[kHeterodyneFrequency] = mOptions.heterodyneFrequency;
    props[kExposureTime] = mOptions.exposureTime;
    props[kPhase] = mOptions.phase;
    props[kTimeSampling] = nameOf(kTimeSamplings, mOptions.timeSampling);
    props[kAntithetic] = nameOf(kAntithetics, mOptions.antithetic);
    props[kSeed] = mOptions.seed;
    Properties velocities;
    for (const auto& [name, motion] : mOptions.velocities)
    {
        Properties motionProps;
        motionProps["linear"] = motion.linear;
        motionProps["angular"] = motion.angular;
        motionProps["center"] = motion.center;
        velocities[name] = motionProps;
    }
    props[kVelocities] = velocities;
    return props;
}

RenderPassReflection DopplerToFPathTracerInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess);
    return reflector;
}

DefineList DopplerToFPathTracerInline::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines = mOptions.pathTracing.getDefines();
    defines.add(LaserState::resolve(renderData).getDefines());
    return defines;
}

void DopplerToFPathTracerInline::setVelocity(const std::string& name, float3 linear, float3 angular, float3 center)
{
    mOptions.velocities[name] = Motion{linear, angular, center};
    mNodesDirty = true;
    mOptionsChanged = true;
}

std::vector<std::tuple<uint32_t, std::string, std::string, bool>> DopplerToFPathTracerInline::getObjectNames() const
{
    std::vector<std::tuple<uint32_t, std::string, std::string, bool>> names;
    if (!mpScene)
        return names;
    for (uint32_t i = 0; i < mpScene->getGeometryInstanceCount(); ++i)
    {
        const GeometryInstanceData& instance = mpScene->getGeometryInstance(i);
        const std::string mesh =
            instance.getType() == GeometryType::TriangleMesh ? mpScene->getMeshName(instance.geometryID) : "";
        names.emplace_back(i, mesh, mpScene->getMaterial(MaterialID(instance.materialID))->getName(), instance.isDynamic());
    }
    return names;
}

void DopplerToFPathTracerInline::findMovingNodes()
{
    // The transforms the scene was built with are the poses at t = 0.
    const auto& locals = mpScene->getAnimationController()->getLocalMatrices();
    if (mBaseTransforms.empty())
        for (uint32_t node = 0; node < locals.size(); ++node)
            mBaseTransforms[node] = locals[node];
    // Restore every node we moved before, then collect the nodes of the named objects.
    for (const auto& moving : mMovingNodes)
        mpScene->updateNodeTransform(moving.nodeID, moving.base);
    mMovingNodes.clear();
    std::map<std::string, bool> used;
    for (const auto& [name, motion] : mOptions.velocities)
        used[name] = false;
    for (const auto& [index, mesh, material, movable] : getObjectNames())
    {
        for (const auto& [name, motion] : mOptions.velocities)
        {
            if (name != mesh && name != material && name != "#" + std::to_string(index))
                continue;
            used[name] = true;
            if (!movable)
            {
                logWarning("DopplerToFPathTracerInline: object '{}' is static and cannot move; build it as animated "
                           "(e.g. addTriangleMesh(..., isAnimated=True) in a .pyscene).", name);
                continue;
            }
            const uint32_t nodeID = mpScene->getGeometryInstance(index).globalMatrixID;
            bool shared = false;
            for (const auto& moving : mMovingNodes)
                shared |= moving.nodeID == nodeID;
            if (shared)
            {
                logWarning("DopplerToFPathTracerInline: '{}' shares its scene-graph node with another moving object, "
                           "so they cannot move separately; load the scene with SceneBuilderFlags.DontOptimizeGraph.",
                           name);
                continue;
            }
            mMovingNodes.push_back({nodeID, mBaseTransforms[nodeID], motion});
        }
    }
    for (const auto& [name, found] : used)
        if (!found)
            logWarning("DopplerToFPathTracerInline: no scene object is named '{}' (mesh or material name).", name);
    mNodesDirty = false;
}

void DopplerToFPathTracerInline::applyPose(RenderContext* pRenderContext, float time)
{
    // Rigid motion over time t: x(t) = center + R(angular t) (x - center) + linear t, applied to the node's base
    // transform (nodes without a parent: the local transform is the world transform).
    for (const auto& moving : mMovingNodes)
    {
        const Motion& m = moving.motion;
        float4x4 motion = math::matrixFromTranslation(m.linear * time);
        const float angle = length(m.angular) * time;
        if (angle != 0.f)
        {
            const float4x4 rotation = math::matrixFromRotation(angle, normalize(m.angular));
            motion = mul(motion, mul(math::matrixFromTranslation(m.center),
                                     mul(rotation, math::matrixFromTranslation(-m.center))));
        }
        mpScene->updateNodeTransform(moving.nodeID, mul(motion, moving.base));
    }
    // Moves the instances and rebuilds the acceleration structure when it is next bound.
    mpScene->update(pRenderContext, 0.0);
}

void DopplerToFPathTracerInline::restoreBasePose()
{
    if (!mpScene)
        return;
    for (const auto& moving : mMovingNodes)
        mpScene->updateNodeTransform(moving.nodeID, moving.base);
}

float DopplerToFPathTracerInline::sampleTime(uint pair) const
{
    double u;
    if (mOptions.timeSampling == TimeSampling::Stratified)
        u = std::fmod(0.5 + (double(pair) + 7919.0 * mOptions.seed) * 0.6180339887498949, 1.0); // golden-ratio sequence
    else
    {
        std::mt19937 rng(pair * 747796405u + mOptions.seed * 2891336453u + 1u);
        u = std::uniform_real_distribution<double>(0.0, 1.0)(rng);
    }
    return float(u * mOptions.exposureTime);
}

void DopplerToFPathTracerInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }
    const ref<Texture> pColor = renderData.getTexture("color");
    if (!mpScene)
    {
        pRenderContext->clearUAV(pColor->getUAV().get(), float4(0.f));
        return;
    }
    if (mNodesDirty)
        findMovingNodes();
    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile,
            getShaderDefines(renderData));
    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator,
        getShaderDefines(renderData));

    // This frame's times: t, and its antithetic partner.
    const uint pair = mFrameCount;
    std::vector<float> times = {sampleTime(pair)};
    const float T = mOptions.exposureTime;
    if (mOptions.antithetic == Antithetic::HalfPeriod)
        times.push_back(float(std::fmod(double(times[0]) + 0.5 / mOptions.heterodyneFrequency, double(T))));
    else if (mOptions.antithetic == Antithetic::Mirror)
        times.push_back(T - times[0]);

    auto var = mpComputePass->getRootVar();
    const uint2 frameDim = uint2(pColor->getWidth(), pColor->getHeight());
    LaserState::resolve(renderData).bindShaderData(var["Laser"]);
    var["gOutputColor"] = pColor;
    var["CB"]["gFrameDim"] = frameDim;
    var["CB"]["gSeedFrame"] = pair + 0x10000u * mOptions.seed; // Same random numbers at both times (random replay).
    var["CB"]["gSamplesPerPixel"] = mOptions.pathTracing.samplesPerPixel;
    var["CB"]["gModulationFrequency"] = mOptions.modulationFrequency * 1e6f;
    var["CB"]["gHeterodyneFrequency"] = mOptions.heterodyneFrequency;
    var["CB"]["gPhase"] = mOptions.phase;
    var["CB"]["gTimeWeight"] = 1.f / float(times.size());
    for (size_t i = 0; i < times.size(); ++i)
    {
        if (!mMovingNodes.empty())
        {
            applyPose(pRenderContext, times[i]);
            mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        }
        var["CB"]["gTime"] = times[i];
        var["CB"]["gAddToOutput"] = i > 0;
        mpComputePass->execute(pRenderContext, uint3(frameDim, 1));
    }
    restoreBasePose();
    mFrameCount++;
}

void DopplerToFPathTracerInline::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    dirty |= widget.var("Modulation frequency (MHz)", mOptions.modulationFrequency, 0.001f, 1e5f);
    dirty |= widget.var("Heterodyne frequency (Hz)", mOptions.heterodyneFrequency, -1e6f, 1e6f);
    dirty |= widget.var("Exposure time (s)", mOptions.exposureTime, 1e-6f, 10.f);
    dirty |= widget.var("Phase (periods)", mOptions.phase, -1.f, 1.f);
    widget.text(fmt::format("Frame (time pair): {}", mFrameCount));
    if (auto group = widget.group("Sampling", true))
        dirty |= mOptions.pathTracing.renderSamplingUI(group, " Each vertex is connected to the light.");
    if (dirty)
        mOptionsChanged = true;
}

void DopplerToFPathTracerInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    restoreBasePose();
    mpComputePass = nullptr;
    mFrameCount = 0;
    mMovingNodes.clear();
    mBaseTransforms.clear();
    mNodesDirty = true;
    mpScene = pScene;
}
