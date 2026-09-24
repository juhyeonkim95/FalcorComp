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
#include "LaserVBufferRT.h"
#include "Scene/HitInfo.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "RenderGraph/RenderPassHelpers.h"

namespace
{
const std::string kProgramRaytraceFile = "RenderPasses/GBuffer/LaserVBuffer/LaserVBufferRT.rt.slang";
const std::string kProgramComputeFile = "RenderPasses/GBuffer/LaserVBuffer/LaserVBufferRT.cs.slang";

// Scripting options.
const char kUseTraceRayInline[] = "useTraceRayInline";
const char kUseDOF[] = "useDOF";
const char kLaserPosition[] = "laserPosition";
const char kLaserDirection[] = "laserDirection";
const char kLaserPower[] = "laserPower";
const char kLaserAngle[] = "laserAngle";
const char kLaserVelocity[] = "laserVelocity";
const char kLaserCollocated[] = "laserCollocated";
const char kIsLightSourceLaser[] = "isLightSourceLaser";


// Ray tracing settings that affect the traversal stack size. Set as small as possible.
// TODO: The shader doesn't need a payload, set this to zero if it's possible to pass a null payload to TraceRay()
const uint32_t kMaxPayloadSizeBytes = 4;
const uint32_t kMaxRecursionDepth = 1;

const std::string kVBufferName = "vbuffer";
const std::string kVBufferDesc = "V-buffer in packed format (indices + barycentrics)";

// Additional output channels.
const ChannelList kVBufferExtraChannels = {
    // clang-format off
    { "depth",          "gDepth",           "Depth buffer (NDC)",               true /* optional */, ResourceFormat::R32Float    },
    { "mvec",           "gMotionVector",    "Motion vector",                    true /* optional */, ResourceFormat::RG32Float   },
    { "viewW",          "gViewW",           "View direction in world space",    true /* optional */, ResourceFormat::RGBA32Float }, // TODO: Switch to packed 2x16-bit snorm format.
    { "time",           "gTime",            "Per-pixel execution time",         true /* optional */, ResourceFormat::R32Uint     },
    { "mask",           "gMask",            "Mask",                             true /* optional */, ResourceFormat::R32Float    },
    // clang-format on
};
}; // namespace




LaserVBufferRT::LaserVBufferRT(ref<Device> pDevice, const Properties& props) : GBufferBase(pDevice)
{
    if (!mpDevice->isShaderModelSupported(ShaderModel::SM6_5))
        FALCOR_THROW("LaserVBufferRT requires Shader Model 6.5 support.");
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
        FALCOR_THROW("LaserVBufferRT requires Raytracing Tier 1.1 support.");

    parseProperties(props);

    // Create sample generator
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_DEFAULT);
}

RenderPassReflection LaserVBufferRT::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    // const uint2 sz = RenderPassHelpers::calculateIOSize(mOutputSizeSelection, mFixedOutputSize, compileData.defaultTexDims);
    const uint2 sz = uint2(1, 1);
    // Add the required output. This always exists.
    reflector.addOutput(kVBufferName, kVBufferDesc)
        .bindFlags(ResourceBindFlags::UnorderedAccess)
        .format(mVBufferFormat)
        .texture2D(sz.x, sz.y);

    // Add all the other outputs.
    addRenderPassOutputs(reflector, kVBufferExtraChannels, ResourceBindFlags::UnorderedAccess, sz);

    return reflector;
}

void LaserVBufferRT::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    GBufferBase::execute(pRenderContext, renderData);

    // Update frame dimension based on render pass output.
    auto pOutput = renderData.getTexture(kVBufferName);
    FALCOR_ASSERT(pOutput);
    updateFrameDim(uint2(pOutput->getWidth(), pOutput->getHeight()));

    if (mpScene)
    {
        // Check for scene changes.
        if (is_set(mUpdateFlags, IScene::UpdateFlags::RecompileNeeded) || is_set(mUpdateFlags, IScene::UpdateFlags::GeometryChanged) ||
            is_set(mUpdateFlags, IScene::UpdateFlags::SDFGridConfigChanged))
        {
            recreatePrograms();
        }

        // Configure depth-of-field.
        // When DOF is enabled, two PRNG dimensions are used. Pass this info to subsequent passes via the dictionary.
        mComputeDOF = mUseDOF && mpScene->getCamera()->getApertureRadius() > 0.f;
        if (mUseDOF)
        {
            renderData.getDictionary()[Falcor::kRenderPassPRNGDimension] = mComputeDOF ? 2u : 0u;
        }
        
        if (mLaserCollocated)
        {
            const auto& pCamera = mpScene->getCamera();
            mLaserPosition = pCamera->getPosition();
            mLaserDirection = normalize(pCamera->getTarget() - pCamera->getPosition());
        }
        // The passes that use the laser read it back with LaserState::resolve().
        LaserState laser;
        laser.origin = mLaserPosition;
        laser.direction = mLaserDirection;
        laser.power = mLaserPower;
        laser.cosAngle = mLaserCosAngle;
        laser.isLaser = mIsLightSourceLaser;
        laser.publish(renderData);

        mUseTraceRayInline ? executeCompute(pRenderContext, renderData) : executeRaytrace(pRenderContext, renderData);
        mUpdateFlags = IScene::UpdateFlags::None;
        mFrameCount++;
    }
    else // If there is no scene, clear the output and return.
    {
        pRenderContext->clearUAV(pOutput->getUAV().get(), uint4(0));
        clearRenderPassChannels(pRenderContext, kVBufferExtraChannels, renderData);
        return;
    }

    mLaserPosition += mLaserVelocity;
}

void LaserVBufferRT::renderUI(Gui::Widgets& widget)
{
    GBufferBase::renderUI(widget);

    if (widget.checkbox("Use TraceRayInline", mUseTraceRayInline))
    {
        mOptionsChanged = true;
    }

    if (widget.checkbox("Use depth-of-field", mUseDOF))
    {
        mOptionsChanged = true;
    }
    widget.tooltip(
        "This option enables stochastic depth-of-field when the camera's aperture radius is nonzero. "
        "Disable it to force the use of a pinhole camera.",
        true
    );

    bool dirty = false;

    float3 laserPower = mLaserPower;
    if (widget.var("laserPower", laserPower, 0.0, FLT_MAX, 0.001f, false, "%.4f"))
    {
        mLaserPower = laserPower;
        dirty = true;
    }

    float3 laserDirection = mLaserDirection;
    if (widget.var("laserDirection", laserDirection, -FLT_MAX, FLT_MAX, 0.001f, false, "%.4f"))
    {
        mLaserDirection = normalize(laserDirection);
        dirty = true;
    }

    float3 laserPosition = mLaserPosition;
    if (widget.var("laserPosition", laserPosition, -FLT_MAX, FLT_MAX, 0.001f, false, "%.4f"))
    {
        mLaserPosition = laserPosition;
        dirty = true;
    }

    float laserAngle = float(std::acos(std::clamp(mLaserCosAngle, -1.f, 1.f)) * 180.0 / M_PI);
    if (widget.var("laserAngle", laserAngle, 0.f, 90.f, 0.1f, false, "%.2f"))
    {
        mLaserCosAngle = float(cos(laserAngle / 180.0 * M_PI));
        dirty = true;
    }
    widget.tooltip("Half-angle of the laser cone in degrees. 0 = collimated beam.", true);

    dirty |= widget.checkbox("Laser source", mIsLightSourceLaser);
    widget.tooltip("On: the light is the spot where the laser beam hits the scene, and the beam length adds to the "
                   "path length.\nOff: a point light at the laser position.", true);

    dirty |= widget.checkbox("Laser collocated", mLaserCollocated);
    widget.tooltip("Place the laser at the camera, aimed at the camera target, instead of at laserPosition and "
                   "laserDirection. The laser follows the camera when it moves.", true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}

Properties LaserVBufferRT::getProperties() const
{
    Properties props = GBufferBase::getProperties();
    props[kUseTraceRayInline] = mUseTraceRayInline;
    props[kUseDOF] = mUseDOF;
    props[kLaserPosition] = mLaserPosition;
    props[kLaserDirection] = mLaserDirection;
    props[kLaserCollocated] = mLaserCollocated;
    props[kIsLightSourceLaser] = mIsLightSourceLaser;
    return props;
}


void LaserVBufferRT::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    GBufferBase::setScene(pRenderContext, pScene);

    recreatePrograms();
}

void LaserVBufferRT::updateLaserInfo(const float3& position, const float3& direction){
    mLaserPosition = position;
    mLaserDirection = direction;
}

void LaserVBufferRT::parseProperties(const Properties& props)
{
    GBufferBase::parseProperties(props);

    for (const auto& [key, value] : props)
    {
        if (key == kUseTraceRayInline)
            mUseTraceRayInline = value;
        else if (key == kUseDOF)
            mUseDOF = value;
        else if (key == kLaserPosition)
            mLaserPosition = value;
        else if (key == kLaserDirection)
            mLaserDirection = value;
        else if (key == kLaserAngle)
            mLaserCosAngle = float(cos(float(value) / 180.0 * M_PI));
        else if (key == kLaserPower)
            mLaserPower = value;
        else if (key == kLaserVelocity)
            mLaserVelocity = value;
        else if (key == kLaserCollocated)
            mLaserCollocated = value;
        else if (key == kIsLightSourceLaser)
            mIsLightSourceLaser = value;
        // TODO: Check for unparsed fields, including those parsed in base classes.
    }
}

void LaserVBufferRT::recreatePrograms()
{
    mRaytrace.pProgram = nullptr;
    mRaytrace.pVars = nullptr;
    mpComputePass = nullptr;
}

void LaserVBufferRT::executeRaytrace(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mRaytrace.pProgram || !mRaytrace.pVars)
    {
        DefineList defines;
        defines.add(mpScene->getSceneDefines());
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getShaderDefines(renderData));

        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kProgramRaytraceFile);
        desc.addTypeConformances(mpScene->getTypeConformances());
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        ref<RtBindingTable> sbt = RtBindingTable::create(1, 1, mpScene->getGeometryCount());
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("miss"));
        sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("closestHit", "anyHit"));

        // Add hit group with intersection shader for triangle meshes with displacement maps.
        if (mpScene->hasGeometryType(Scene::GeometryType::DisplacedTriangleMesh))
        {
            sbt->setHitGroup(
                0,
                mpScene->getGeometryIDs(Scene::GeometryType::DisplacedTriangleMesh),
                desc.addHitGroup("displacedTriangleMeshClosestHit", "", "displacedTriangleMeshIntersection")
            );
        }

        // Add hit group with intersection shader for curves (represented as linear swept spheres).
        if (mpScene->hasGeometryType(Scene::GeometryType::Curve))
        {
            sbt->setHitGroup(
                0, mpScene->getGeometryIDs(Scene::GeometryType::Curve), desc.addHitGroup("curveClosestHit", "", "curveIntersection")
            );
        }

        // Add hit group with intersection shader for SDF grids.
        if (mpScene->hasGeometryType(Scene::GeometryType::SDFGrid))
        {
            sbt->setHitGroup(
                0, mpScene->getGeometryIDs(Scene::GeometryType::SDFGrid), desc.addHitGroup("sdfGridClosestHit", "", "sdfGridIntersection")
            );
        }

        mRaytrace.pProgram = Program::create(mpDevice, desc, defines);
        mRaytrace.pVars = RtProgramVars::create(mpDevice, mRaytrace.pProgram, sbt);

        // Bind static resources.
        ShaderVar var = mRaytrace.pVars->getRootVar();
        mpSampleGenerator->bindShaderData(var);
    }

    mRaytrace.pProgram->addDefines(getShaderDefines(renderData));

    ShaderVar var = mRaytrace.pVars->getRootVar();
    bindShaderData(var, renderData);

    // Dispatch the rays.
    mpScene->raytrace(pRenderContext, mRaytrace.pProgram.get(), mRaytrace.pVars, uint3(1, 1, 1));
}

void LaserVBufferRT::executeCompute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Create compute pass.
    if (!mpComputePass)
    {
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kProgramComputeFile).csEntry("main");
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

    mpComputePass->getProgram()->addDefines(getShaderDefines(renderData));

    ShaderVar var = mpComputePass->getRootVar();
    bindShaderData(var, renderData);

    mpComputePass->execute(pRenderContext, uint3(mFrameDim, 1));
}


DefineList LaserVBufferRT::getShaderDefines(const RenderData& renderData) const
{
    DefineList defines;
    defines.add("COMPUTE_DEPTH_OF_FIELD", mComputeDOF ? "1" : "0");
    defines.add("USE_ALPHA_TEST", mUseAlphaTest ? "1" : "0");

    // Setup ray flags.
    RayFlags rayFlags = RayFlags::None;
    if (mForceCullMode && mCullMode == RasterizerState::CullMode::Front)
        rayFlags = RayFlags::CullFrontFacingTriangles;
    else if (mForceCullMode && mCullMode == RasterizerState::CullMode::Back)
        rayFlags = RayFlags::CullBackFacingTriangles;
    defines.add("RAY_FLAGS", std::to_string((uint32_t)rayFlags));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    defines.add(getValidResourceDefines(kVBufferExtraChannels, renderData));
    return defines;
}

void LaserVBufferRT::bindShaderData(const ShaderVar& var, const RenderData& renderData)
{
    var["gLaserVBufferRT"]["frameDim"] = mFrameDim;
    var["gLaserVBufferRT"]["frameCount"] = mFrameCount;
    
    var["gLaserVBufferRT"]["laserPosition"] = mLaserPosition;
    var["gLaserVBufferRT"]["laserDirection"] = mLaserDirection;
    // var["gLaserVBufferRT"]["laserPower"] = mLaserPower;
    // var["gLaserVBufferRT"]["laserCosAngle"] = mLaserCosAngle;
    
    // Bind resources.
    var["gVBuffer"] = getOutput(renderData, kVBufferName);

    // Bind output channels as UAV buffers.
    auto bind = [&](const ChannelDesc& channel)
    {
        ref<Texture> pTex = getOutput(renderData, channel.name);
        var[channel.texname] = pTex;
    };
    for (const auto& channel : kVBufferExtraChannels)
        bind(channel);
}
