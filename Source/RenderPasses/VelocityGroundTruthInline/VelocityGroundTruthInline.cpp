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
#include "VelocityGroundTruthInline.h"
#include "RenderGraph/RenderPassHelpers.h"

static void regVelocityGroundTruthInline(pybind11::module& m)
{
    using namespace pybind11::literals;
    pybind11::class_<VelocityGroundTruthInline, RenderPass, ref<VelocityGroundTruthInline>> pass(m, "VelocityGroundTruthInline");
    pass.def("set_velocity", &VelocityGroundTruthInline::setVelocity, "name"_a, "linear"_a,
        "angular"_a = float3(0.f), "center"_a = float3(0.f));
    pass.def("get_object_names", &VelocityGroundTruthInline::getObjectNames);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, VelocityGroundTruthInline>();
    ScriptBindings::registerBinding(regVelocityGroundTruthInline);
}

namespace
{
const char kShaderFile[] = "RenderPasses/VelocityGroundTruthInline/VelocityGroundTruthInline.cs.slang";
const char kPassName[] = "VelocityGroundTruthInline";
const ChannelList kOutputChannels = {
    { "velocity", "gVelocity", "Velocity of the direct path (m/s); NaN without a hit", false, ResourceFormat::R32Float },
};
const std::map<std::string, VelocityGroundTruthInline::Mode> kModes = {
    {"doppler", VelocityGroundTruthInline::Mode::Doppler},
    {"path_length", VelocityGroundTruthInline::Mode::PathLength},
    {"projection", VelocityGroundTruthInline::Mode::Projection},
};
} // namespace

VelocityGroundTruthInline::VelocityGroundTruthInline(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
}

void VelocityGroundTruthInline::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == "mode")
        {
            const std::string mode = value;
            auto it = kModes.find(mode);
            if (it == kModes.end())
                FALCOR_THROW("mode must be doppler, path_length or projection.");
            mOptions.mode = it->second;
        }
        else if (key == "dt")
            mOptions.dt = value;
        else if (key == "direction")
            mOptions.direction = value;
        else if (key == "sensorVelocity")
            mOptions.sensorVelocity = value;
        else if (key == "lightVelocity")
            mOptions.lightVelocity = value;
        else if (key == "velocities")
            mOptions.velocities = parseObjectMotions(value);
        else
            logWarning("Unknown property '{}' in {} properties.", key, kPassName);
    }
}

void VelocityGroundTruthInline::validateOptions(const Options& options)
{
    if (options.mode == Mode::PathLength && !(options.dt > 0.f))
        FALCOR_THROW("dt must be positive.");
    if (!(length(options.direction) > 0.f))
        FALCOR_THROW("direction must be nonzero.");
}

void VelocityGroundTruthInline::setProperties(const Properties& props)
{
    // Invalid properties throw and leave the options unchanged.
    InlinePass::applyProperties(mOptions, [&] { parseProperties(props); }, validateOptions);
    // The velocity buffer and, for path_length, the moving nodes follow the motions and the mode.
    if (props.has("velocities") || props.has("mode"))
        mVelocitiesDirty = true;
}

Properties VelocityGroundTruthInline::getProperties() const
{
    Properties props;
    for (const auto& [name, mode] : kModes)
        if (mode == mOptions.mode)
            props["mode"] = name;
    props["dt"] = mOptions.dt;
    props["direction"] = mOptions.direction;
    props["sensorVelocity"] = mOptions.sensorVelocity;
    props["lightVelocity"] = mOptions.lightVelocity;
    props["velocities"] = serializeObjectMotions(mOptions.velocities);
    return props;
}

RenderPassReflection VelocityGroundTruthInline::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess);
    return reflector;
}

void VelocityGroundTruthInline::setVelocity(const std::string& name, float3 linear, float3 angular, float3 center)
{
    mOptions.velocities[name] = ObjectMotion{linear, angular, center};
    mVelocitiesDirty = true;
}

std::vector<std::tuple<uint32_t, std::string, std::string, bool>> VelocityGroundTruthInline::getObjectNames() const
{
    std::vector<std::tuple<uint32_t, std::string, std::string, bool>> names;
    if (mpScene)
        for (const auto& object : listSceneObjects(*mpScene))
            names.emplace_back(object.instance, object.mesh, object.material, object.movable);
    return names;
}

void VelocityGroundTruthInline::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    mLaserInput.update(renderData, "VelocityGroundTruthInline");
    const ref<Texture> pVelocity = renderData.getTexture("velocity");
    if (!mpScene)
    {
        pRenderContext->clearUAV(pVelocity->getUAV().get(), float4(0.f));
        return;
    }
    if (mVelocitiesDirty)
    {
        mpInstanceVelocities = createInstanceVelocityBuffer(mpDevice, *mpScene, mOptions.velocities, kPassName);
        if (mOptions.mode == Mode::PathLength)
            mMover.prepare(mpScene, mOptions.velocities, kPassName);
        mVelocitiesDirty = false;
    }
    DefineList defines = mLaserInput.get().getDefines();
    if (!mpComputePass)
        mpComputePass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, defines);
    InlinePass::updateScenePassDefines(pRenderContext, mpComputePass, mpScene, mpSampleGenerator, defines);

    const uint2 frameDim = uint2(pVelocity->getWidth(), pVelocity->getHeight());
    if (!mpFirstLength || mpFirstLength->getWidth() != frameDim.x || mpFirstLength->getHeight() != frameDim.y)
        mpFirstLength = mpDevice->createTexture2D(frameDim.x, frameDim.y, ResourceFormat::RG32Float, 1, 1, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);

    auto var = mpComputePass->getRootVar();
    mLaserInput.get().bindShaderData(var["Laser"]);
    var["gVelocity"] = pVelocity;
    var["gFirstLength"] = mpFirstLength;
    var["gInstanceVelocities"] = mpInstanceVelocities;
    var["CB"]["gFrameDim"] = frameDim;
    var["CB"]["gMode"] = uint(mOptions.mode);
    var["CB"]["gDirection"] = normalize(mOptions.direction);
    var["CB"]["gSensorVelocity"] = mOptions.sensorVelocity;
    var["CB"]["gLightVelocity"] = mOptions.lightVelocity;
    var["CB"]["gDt"] = mOptions.dt;

    // path_length: the path length at time 0 (the scene's pose), then again at dt, along the same pixel rays.
    // Rebind the scene first: the last frame moved it to dt and back, and the binding still holds the TLAS of the
    // moved pose.
    if (mOptions.mode == Mode::PathLength && !mMover.empty())
        mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
    var["CB"]["gStage"] = 0u;
    mpComputePass->execute(pRenderContext, uint3(frameDim, 1));
    if (mOptions.mode == Mode::PathLength)
    {
        if (!mMover.empty())
        {
            mMover.apply(pRenderContext, mOptions.dt);
            mpScene->bindShaderDataForRaytracing(pRenderContext, var["gScene"]);
        }
        var["CB"]["gStage"] = 1u;
        mpComputePass->execute(pRenderContext, uint3(frameDim, 1));
        mMover.restore();
    }
}

void VelocityGroundTruthInline::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mMover.reset();
    mpComputePass = nullptr;
    mVelocitiesDirty = true;
    mpScene = pScene;
}
