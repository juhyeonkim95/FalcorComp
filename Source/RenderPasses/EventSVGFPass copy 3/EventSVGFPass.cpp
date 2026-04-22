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
#include "EventSVGFPass.h"

/*
TODO:
- clean up shaders
- clean up UI: tooltips, etc.
- handle skybox pixels
- enum for fbo channel indices
*/

namespace
{
// Shader source files
const char kPackLinearZAndNormalShader[] = "RenderPasses/EventSVGFPass/EventSVGFPackLinearZAndNormal.ps.slang";
const char kReprojectShader[] = "RenderPasses/EventSVGFPass/EventSVGFReproject.ps.slang";
const char kAtrousShader[] = "RenderPasses/EventSVGFPass/EventSVGFAtrous.ps.slang";
const char kFilterMomentShader[] = "RenderPasses/EventSVGFPass/EventSVGFFilterMoments.ps.slang";
const char kFinalModulateShader[] = "RenderPasses/EventSVGFPass/EventSVGFFinalModulate.ps.slang";

// Names of valid entries in the parameter dictionary.
const char kEnabled[] = "Enabled";
const char kIterations[] = "Iterations";
const char kFeedbackTap[] = "FeedbackTap";
const char kVarianceEpsilon[] = "VarianceEpsilon";
const char kPhiColor[] = "PhiColor";
const char kPhiNormal[] = "PhiNormal";
const char kAlpha[] = "Alpha";
const char kMomentsAlpha[] = "MomentsAlpha";
const char kUseDemodulation[] = "UseDemodulation";
const char kUseMotionVectorAlignDifference[] = "UseMotionVectorAlignDifference";
const char kOutputMotionVectorAlignDifference[] = "OutputMotionVectorAlignDifference";

// Input buffer names
const char kInputBufferAlbedo[] = "Albedo";
const char kInputBufferColor[] = "Color";
const char kInputBufferColor2[] = "Color2";
const char kInputBufferEmission[] = "Emission";
const char kInputBufferWorldPosition[] = "WorldPosition";
const char kInputBufferWorldNormal[] = "WorldNormal";
const char kInputBufferPosNormalFwidth[] = "PositionNormalFwidth";
const char kInputBufferLinearZ[] = "LinearZ";
const char kInputBufferMotionVector[] = "MotionVec";

// Internal buffer names
const char kInternalBufferPreviousLinearZAndNormal[] = "Previous Linear Z and Packed Normal";
const char kInternalBufferPreviousPreviousLinearZAndNormal[] = "Previous Previous Linear Z and Packed Normal";
const char kInternalBufferPreviousAlbedo[] = "Previous Albedo";
const char kInternalBufferPreviousEmission[] = "Previous Emission";
const char kInternalBufferPreviousLighting[] = "Previous Lighting";
const char kInternalBufferPreviousMoments[] = "Previous Moments";
const char kInternalBufferPreviousMotion[] = "Previous Motion";

// Output buffer name
const char kOutputBufferFilteredImage[] = "Filtered image";
} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, EventSVGFPass>();
}

EventSVGFPass::EventSVGFPass(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kEnabled)
            mFilterEnabled = value;
        else if (key == kIterations)
            mFilterIterations = value;
        else if (key == kFeedbackTap)
            mFeedbackTap = value;
        else if (key == kVarianceEpsilon)
            mVarainceEpsilon = value;
        else if (key == kPhiColor)
            mPhiColor = value;
        else if (key == kPhiNormal)
            mPhiNormal = value;
        else if (key == kAlpha)
            mAlpha = value;
        else if (key == kMomentsAlpha)
            mMomentsAlpha = value;
        else if (key == kUseDemodulation)
            mUseDemodulation = value;
        else if (key == kUseMotionVectorAlignDifference)
            mUseMotionVectorAlignDifference = value;
        else if (key == kOutputMotionVectorAlignDifference)
            mOutputMotionVectorAlignDifference = value;
        else
            logWarning("Unknown property '{}' in EventSVGFPass properties.", key);
    }

    mpPackLinearZAndNormal = FullScreenPass::create(mpDevice, kPackLinearZAndNormalShader);
    mpReprojection = FullScreenPass::create(mpDevice, kReprojectShader);
    mpAtrous = FullScreenPass::create(mpDevice, kAtrousShader);
    mpFilterMoments = FullScreenPass::create(mpDevice, kFilterMomentShader);
    mpFinalModulate = FullScreenPass::create(mpDevice, kFinalModulateShader);
    FALCOR_ASSERT(mpPackLinearZAndNormal && mpReprojection && mpAtrous && mpFilterMoments && mpFinalModulate);
}

Properties EventSVGFPass::getProperties() const
{
    Properties props;
    props[kEnabled] = mFilterEnabled;
    props[kIterations] = mFilterIterations;
    props[kFeedbackTap] = mFeedbackTap;
    props[kVarianceEpsilon] = mVarainceEpsilon;
    props[kPhiColor] = mPhiColor;
    props[kPhiNormal] = mPhiNormal;
    props[kAlpha] = mAlpha;
    props[kMomentsAlpha] = mMomentsAlpha;
    return props;
}

/*
Reproject:
  - takes: motion, color, prevLighting, prevMoments, linearZ, prevLinearZ, historyLen
    returns: illumination, moments, historyLength
Variance/filter moments:
  - takes: illumination, moments, history length, normal+depth
  - returns: filtered illumination+variance (to ping pong fbo)
a-trous:
  - takes: albedo, filtered illumination+variance, normal+depth, history length
  - returns: final color
*/

RenderPassReflection EventSVGFPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    reflector.addInput(kInputBufferAlbedo, "Albedo");
    reflector.addInput(kInputBufferColor, "Color");
    reflector.addInput(kInputBufferColor2, "Color2");
    reflector.addInput(kInputBufferEmission, "Emission");
    reflector.addInput(kInputBufferWorldPosition, "World Position");
    reflector.addInput(kInputBufferWorldNormal, "World Normal");
    reflector.addInput(kInputBufferPosNormalFwidth, "PositionNormalFwidth");
    reflector.addInput(kInputBufferLinearZ, "LinearZ");
    reflector.addInput(kInputBufferMotionVector, "Motion vectors");

    reflector.addInternal(kInternalBufferPreviousLinearZAndNormal, "Previous Linear Z and Packed Normal")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousPreviousLinearZAndNormal, "Previous Previous Linear Z and Packed Normal")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousLighting, "Previous Filtered Lighting")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousMoments, "Previous Moments")
        .format(ResourceFormat::RG32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousAlbedo, "Previous Albedo")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousMotion, "Previous Motion")
        .format(ResourceFormat::RG32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);
    reflector.addInternal(kInternalBufferPreviousEmission, "Previous Emission")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::RenderTarget | ResourceBindFlags::ShaderResource);

    reflector.addOutput(kOutputBufferFilteredImage, "Filtered image").format(ResourceFormat::RGBA32Float);

    return reflector;
}

void EventSVGFPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    allocateFbos(compileData.defaultTexDims, pRenderContext);
    mBuffersNeedClear = true;
}

void EventSVGFPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    ref<Texture> pAlbedoTexture = renderData.getTexture(kInputBufferAlbedo);
    ref<Texture> pColorTexture = renderData.getTexture(kInputBufferColor);
    ref<Texture> pColor2Texture = renderData.getTexture(kInputBufferColor2);
    ref<Texture> pEmissionTexture = renderData.getTexture(kInputBufferEmission);
    ref<Texture> pWorldPositionTexture = renderData.getTexture(kInputBufferWorldPosition);
    ref<Texture> pWorldNormalTexture = renderData.getTexture(kInputBufferWorldNormal);
    ref<Texture> pPosNormalFwidthTexture = renderData.getTexture(kInputBufferPosNormalFwidth);
    ref<Texture> pLinearZTexture = renderData.getTexture(kInputBufferLinearZ);
    ref<Texture> pMotionVectorTexture = renderData.getTexture(kInputBufferMotionVector);

    ref<Texture> pOutputTexture = renderData.getTexture(kOutputBufferFilteredImage);

    FALCOR_ASSERT(
        mpFilteredIlluminationFbo && mpFilteredIlluminationFbo->getWidth() == pAlbedoTexture->getWidth() &&
        mpFilteredIlluminationFbo->getHeight() == pAlbedoTexture->getHeight()
    );

    if (mBuffersNeedClear)
    {
        clearBuffers(pRenderContext, renderData);
        mBuffersNeedClear = false;
    }

    if (mFilterEnabled)
    {
        // Grab linear z and its derivative and also pack the normal into
        // the last two channels of the mpLinearZAndNormalFbo.
        computeLinearZAndNormal(pRenderContext, pLinearZTexture, pWorldNormalTexture);

        // Demodulate input color & albedo to get illumination and lerp in
        // reprojected filtered illumination from the previous frame.
        // Stores the result as well as initial moments and an updated
        // per-pixel history length in mpCurReprojFbo.
        ref<Texture> pPrevAlbedoTexture = renderData.getTexture(kInternalBufferPreviousAlbedo);
        ref<Texture> pPrevMotionTexture = renderData.getTexture(kInternalBufferPreviousMotion);
        ref<Texture> pPrevEmissionTexture = renderData.getTexture(kInternalBufferPreviousEmission);
        ref<Texture> pPrevLinearZAndNormalTexture = renderData.getTexture(kInternalBufferPreviousLinearZAndNormal);
        ref<Texture> pPrevPrevLinearZAndNormalTexture = renderData.getTexture(kInternalBufferPreviousPreviousLinearZAndNormal);
        ref<Texture> pPrevLightingTexture = renderData.getTexture(kInternalBufferPreviousLighting);
        computeReprojection(
            pRenderContext,
            pAlbedoTexture,
            pPrevAlbedoTexture,
            pColorTexture,
            pColor2Texture,
            pEmissionTexture,
            pPrevEmissionTexture,
            pMotionVectorTexture,
            pPrevMotionTexture,
            pPosNormalFwidthTexture,
            pPrevLinearZAndNormalTexture,
            pPrevPrevLinearZAndNormalTexture
        );

        // Do a first cross-bilateral filtering of the illumination and
        // estimate its variance, storing the result into a float4 in
        // mpPingPongFbo[0].  Takes mpCurReprojFbo as input.
        computeFilteredMoments(pRenderContext, pPrevLinearZAndNormalTexture);

        // Filter illumination from mpCurReprojFbo[0], storing the result
        // in mpPingPongFbo[0].  Along the way (or at the end, depending on
        // the value of mFeedbackTap), save the filtered illumination for
        // next time into mpFilteredPastFbo.
        computeAtrousDecomposition(pRenderContext, pAlbedoTexture, pPrevLinearZAndNormalTexture, pMotionVectorTexture);

        // Compute albedo * filtered illumination and add emission back in.
        auto perImageCB = mpFinalModulate->getRootVar()["PerImageCB"];
        perImageCB["gAlbedo"] = pAlbedoTexture;
        perImageCB["gEmission"] = pEmissionTexture;
        perImageCB["gPrevAlbedo"] = pPrevAlbedoTexture;
        perImageCB["gPrevEmission"] = pPrevEmissionTexture;
        perImageCB["gIllumination"] = mpPingPongFbo[0]->getColorTexture(0);
        perImageCB["gPrevIllumination"] = pPrevLightingTexture;
        perImageCB["gColor"] = pColorTexture;
        perImageCB["gPrevColor2"] = mpPrevColor2Fbo->getColorTexture(0);
        perImageCB["gUseDemodulation"] = int(mUseDemodulation);
        perImageCB["gUseMotionVectorAlignDifference"] = int(mUseMotionVectorAlignDifference);
        perImageCB["gOutputMotionVectorAlignDifference"] = int(mOutputMotionVectorAlignDifference);
        perImageCB["gMotion"] = pMotionVectorTexture;
        perImageCB["gPositionNormalFwidth"] = pPosNormalFwidthTexture;
        perImageCB["gLinearZAndNormal"] = mpLinearZAndNormalFbo->getColorTexture(0);
        perImageCB["gPrevLinearZAndNormal"] = pPrevLinearZAndNormalTexture;
        mpFinalModulate->execute(pRenderContext, mpFinalFbo);

        // Blit into the output texture.
        pRenderContext->blit(mpFinalFbo->getColorTexture(0)->getSRV(), pOutputTexture->getRTV());

        // Swap resources so we're ready for next frame.
        std::swap(mpCurReprojFbo, mpPrevReprojFbo);
        pRenderContext->blit(pPrevLinearZAndNormalTexture->getSRV(), pPrevPrevLinearZAndNormalTexture->getRTV());
        pRenderContext->blit(mpLinearZAndNormalFbo->getColorTexture(0)->getSRV(), pPrevLinearZAndNormalTexture->getRTV());
        pRenderContext->blit(pAlbedoTexture->getSRV(), pPrevAlbedoTexture->getRTV());
        pRenderContext->blit(pEmissionTexture->getSRV(), pPrevEmissionTexture->getRTV());
        pRenderContext->blit(pMotionVectorTexture->getSRV(), pPrevMotionTexture->getRTV());
        pRenderContext->blit(mpPingPongFbo[0]->getColorTexture(0)->getSRV(), pPrevLightingTexture->getRTV());
    }
    else
    {
        pRenderContext->blit(pColorTexture->getSRV(), pOutputTexture->getRTV());
    }

    // copy color2
    pRenderContext->blit(pColor2Texture->getSRV(), mpPrevColor2Fbo->getColorTexture(0)->getRTV());
    mFrameCount += 1;
}

void EventSVGFPass::allocateFbos(uint2 dim, RenderContext* pRenderContext)
{
    {
        // Screen-size FBOs with 3 MRTs: one that is RGBA32F, one that is
        // RG32F for the luminance moments, and one that is R16F.
        Fbo::Desc desc;
        desc.setSampleCount(0);
        desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float); // illumination
        desc.setColorTarget(1, Falcor::ResourceFormat::RG32Float);   // moments
        desc.setColorTarget(2, Falcor::ResourceFormat::RG16Float);    // history length
        desc.setColorTarget(3, Falcor::ResourceFormat::RGBA32Float); // prev illumination
        mpCurReprojFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpPrevReprojFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
    }

    {
        // Screen-size RGBA32F buffer for linear Z, derivative, and packed normal
        Fbo::Desc desc;
        desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
        mpLinearZAndNormalFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpPrevColor2Fbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
    }

    {
        // Screen-size FBOs with 1 RGBA32F buffer
        Fbo::Desc desc;
        desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
        mpPingPongFbo[0] = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpPingPongFbo[1] = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpFilteredPastFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpFilteredPastPastFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpFilteredIlluminationFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpFinalFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
    }

    mBuffersNeedClear = true;
}

void EventSVGFPass::clearBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    pRenderContext->clearFbo(mpPingPongFbo[0].get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpPingPongFbo[1].get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpLinearZAndNormalFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpFilteredPastFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpFilteredPastPastFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpCurReprojFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpPrevReprojFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpFilteredIlluminationFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpPrevColor2Fbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);

    pRenderContext->clearTexture(renderData.getTexture(kInternalBufferPreviousLinearZAndNormal).get());
    pRenderContext->clearTexture(renderData.getTexture(kInternalBufferPreviousPreviousLinearZAndNormal).get());
    pRenderContext->clearTexture(renderData.getTexture(kInternalBufferPreviousLighting).get());
    pRenderContext->clearTexture(renderData.getTexture(kInternalBufferPreviousMoments).get());
    pRenderContext->clearTexture(renderData.getTexture(kInternalBufferPreviousAlbedo).get());
    pRenderContext->clearTexture(renderData.getTexture(kInternalBufferPreviousEmission).get());
}

// Extracts linear z and its derivative from the linear Z texture and packs
// the normal from the world normal texture and packes them into the FBO.
// (It's slightly wasteful to copy linear z here, but having this all
// together in a single buffer is a small simplification, since we make a
// copy of it to refer to in the next frame.)
void EventSVGFPass::computeLinearZAndNormal(RenderContext* pRenderContext, ref<Texture> pLinearZTexture, ref<Texture> pWorldNormalTexture)
{
    auto perImageCB = mpPackLinearZAndNormal->getRootVar()["PerImageCB"];
    perImageCB["gLinearZ"] = pLinearZTexture;
    perImageCB["gNormal"] = pWorldNormalTexture;

    mpPackLinearZAndNormal->execute(pRenderContext, mpLinearZAndNormalFbo);
}

void EventSVGFPass::computeReprojection(
    RenderContext* pRenderContext,
    ref<Texture> pAlbedoTexture,
    ref<Texture> pPrevAlbedoTexture,
    ref<Texture> pColorTexture,
    ref<Texture> pColor2Texture,
    ref<Texture> pEmissionTexture,
    ref<Texture> pPrevEmissionTexture,
    ref<Texture> pMotionVectorTexture,
    ref<Texture> pPrevMotionVectorTexture,
    ref<Texture> pPositionNormalFwidthTexture,
    ref<Texture> pPrevLinearZTexture,
    ref<Texture> pPrevPrevLinearZTexture
)
{
    auto perImageCB = mpReprojection->getRootVar()["PerImageCB"];

    // Setup textures for our reprojection shader pass
    perImageCB["gMotion"] = pMotionVectorTexture;
    // perImageCB["gPrevMotion"] = pPrevMotionVectorTexture;
    perImageCB["gColor"] = pColorTexture;
    perImageCB["gColor2"] = pColor2Texture;
    perImageCB["gPrevColor2"] = mpPrevColor2Fbo->getColorTexture(0);
    perImageCB["gEmission"] = pEmissionTexture;
    perImageCB["gPrevEmission"] = pPrevEmissionTexture;
    perImageCB["gAlbedo"] = pAlbedoTexture;
    perImageCB["gPrevAlbedo"] = pPrevAlbedoTexture;
    perImageCB["gPositionNormalFwidth"] = pPositionNormalFwidthTexture;
    perImageCB["gPrevIllum"] = mpFilteredPastFbo->getColorTexture(0);
    perImageCB["gPrevReprojIllum"] = mpPrevReprojFbo->getColorTexture(3);
    perImageCB["gPrevPrevIllum"] = mpFilteredPastPastFbo->getColorTexture(0);
    perImageCB["gPrevMoments"] = mpPrevReprojFbo->getColorTexture(1);
    perImageCB["gLinearZAndNormal"] = mpLinearZAndNormalFbo->getColorTexture(0);
    perImageCB["gPrevLinearZAndNormal"] = pPrevLinearZTexture;
    perImageCB["gPrevPrevLinearZAndNormal"] = pPrevPrevLinearZTexture;
    perImageCB["gPrevHistoryLength"] = mpPrevReprojFbo->getColorTexture(2);

    // Setup variables for our reprojection pass
    perImageCB["gAlpha"] = mAlpha;
    perImageCB["gMomentsAlpha"] = mMomentsAlpha;
    perImageCB["gFrameCount"] = mFrameCount;
    perImageCB["gUseDemodulation"] = int(mUseDemodulation);
    perImageCB["gUseMotionVectorAlignDifference"] = int(mUseMotionVectorAlignDifference);

    mpReprojection->execute(pRenderContext, mpCurReprojFbo);
}

void EventSVGFPass::computeFilteredMoments(RenderContext* pRenderContext, ref<Texture> pPrevLinearZAndNormalTexture)
{
    auto perImageCB = mpFilterMoments->getRootVar()["PerImageCB"];

    perImageCB["gIllumination"] = mpCurReprojFbo->getColorTexture(0);
    perImageCB["gHistoryLength"] = mpCurReprojFbo->getColorTexture(2);
    perImageCB["gLinearZAndNormal"] = mpLinearZAndNormalFbo->getColorTexture(0);
    perImageCB["gPrevLinearZAndNormal"] = pPrevLinearZAndNormalTexture;
    perImageCB["gMoments"] = mpCurReprojFbo->getColorTexture(1);

    perImageCB["gPhiColor"] = mPhiColor;
    perImageCB["gPhiNormal"] = mPhiNormal;

    mpFilterMoments->execute(pRenderContext, mpPingPongFbo[0]);
}

void EventSVGFPass::computeAtrousDecomposition(RenderContext* pRenderContext,
     ref<Texture> pAlbedoTexture, ref<Texture> pPrevLinearZAndNormalTexture, 
     ref<Texture> pMotionVectorTexture
    )
{
    auto perImageCB = mpAtrous->getRootVar()["PerImageCB"];

    perImageCB["gAlbedo"] = pAlbedoTexture;
    perImageCB["gHistoryLength"] = mpCurReprojFbo->getColorTexture(2);
    perImageCB["gLinearZAndNormal"] = mpLinearZAndNormalFbo->getColorTexture(0);
    perImageCB["gPrevLinearZAndNormal"] = pPrevLinearZAndNormalTexture;
    perImageCB["gMotion"] = pMotionVectorTexture;

    perImageCB["gPhiColor"] = mPhiColor;
    perImageCB["gPhiNormal"] = mPhiNormal;
    perImageCB["gUseMotionVectorAlignDifference"] = int(mUseMotionVectorAlignDifference);

    for (int i = 0; i < mFilterIterations; i++)
    {
        ref<Fbo> curTargetFbo = mpPingPongFbo[1];

        perImageCB["gIllumination"] = mpPingPongFbo[0]->getColorTexture(0);
        perImageCB["gStepSize"] = 1 << i;

        mpAtrous->execute(pRenderContext, curTargetFbo);

        // store the filtered color for the feedback path
        if (i == std::min(mFeedbackTap, mFilterIterations - 1))
        {
            pRenderContext->blit(mpFilteredPastFbo->getColorTexture(0)->getSRV(), mpFilteredPastPastFbo->getRenderTargetView(0));
            pRenderContext->blit(curTargetFbo->getColorTexture(0)->getSRV(), mpFilteredPastFbo->getRenderTargetView(0));
        }

        std::swap(mpPingPongFbo[0], mpPingPongFbo[1]);
    }

    if (mFeedbackTap < 0)
    {
        pRenderContext->blit(mpFilteredPastFbo->getColorTexture(0)->getSRV(), mpFilteredPastPastFbo->getRenderTargetView(0));
        pRenderContext->blit(mpCurReprojFbo->getColorTexture(0)->getSRV(), mpFilteredPastFbo->getRenderTargetView(0));
    }
}

void EventSVGFPass::renderUI(Gui::Widgets& widget)
{
    int dirty = 0;
    dirty |= (int)widget.checkbox("Enable EventSVGF", mFilterEnabled);

    widget.text("");
    widget.text("Number of filter iterations.  Which");
    widget.text("    iteration feeds into future frames?");
    dirty |= (int)widget.var("Iterations", mFilterIterations, 2, 10, 1);
    dirty |= (int)widget.var("Feedback", mFeedbackTap, -1, mFilterIterations - 2, 1);

    widget.text("");
    widget.text("Contol edge stopping on bilateral fitler");
    dirty |= (int)widget.var("For Color", mPhiColor, 0.0f, 10000.0f, 0.01f);
    dirty |= (int)widget.var("For Normal", mPhiNormal, 0.001f, 1000.0f, 0.2f);

    widget.text("");
    widget.text("How much history should be used?");
    widget.text("    (alpha; 0 = full reuse; 1 = no reuse)");
    dirty |= (int)widget.var("Alpha", mAlpha, 0.0f, 1.0f, 0.001f);
    dirty |= (int)widget.var("Moments Alpha", mMomentsAlpha, 0.0f, 1.0f, 0.001f);

    if (dirty)
        mBuffersNeedClear = true;
}
