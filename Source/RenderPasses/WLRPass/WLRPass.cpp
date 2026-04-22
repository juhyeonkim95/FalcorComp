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
#include "WLRPass.h"

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
const char kPackLinearZAndNormalShader[] = "RenderPasses/WLRPass/WLRPackLinearZAndNormal.ps.slang";
const char kWLRDenoiseShader[] = "RenderPasses/WLRPass/WLRDenoiseSimple.ps.slang";

// Names of valid entries in the parameter dictionary.
const char kEnabled[] = "Enabled";
const char kKernelRadius[] = "KernelRadius";
const char kSigmaSpatial[] = "SigmaSpatial";
const char kSigmaAlbedo[] = "SigmaAlbedo";
const char kSigmaDepth[] = "SigmaDepth";
const char kSigmaNormal[] = "SigmaNormal";
const char kMinWeight[] = "MinWeight";
const char kRegressionLambda[] = "RegressionLambda";

// Input buffer names
const char kInputBufferAlbedo[] = "Albedo";
const char kInputBufferColor[] = "Color";
const char kInputBufferEmission[] = "Emission";
const char kInputBufferWorldPosition[] = "WorldPosition";
const char kInputBufferWorldNormal[] = "WorldNormal";
const char kInputBufferPosNormalFwidth[] = "PositionNormalFwidth";
const char kInputBufferLinearZ[] = "LinearZ";
const char kInputBufferMotionVector[] = "MotionVec";

// Output buffer name
const char kOutputBufferFilteredImage[] = "Filtered image";
} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, WLRPass>();
}

WLRPass::WLRPass(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kEnabled)
            mFilterEnabled = value;
        else if (key == kKernelRadius)
            mKernelRadius = value;
        else if (key == kSigmaSpatial)
            mSigmaSpatial = value;
        else if (key == kSigmaAlbedo)
            mSigmaAlbedo = value;
        else if (key == kSigmaDepth)
            mSigmaDepth = value;
        else if (key == kSigmaNormal)
            mSigmaNormal = value;
        else if (key == kMinWeight)
            mMinWeight = value;
        else if (key == kRegressionLambda)
            mRegressionLambda = value;
        else
            logWarning("Unknown property '{}' in WLRPass properties.", key);
    }

    mpPackLinearZAndNormal = FullScreenPass::create(mpDevice, kPackLinearZAndNormalShader);
    mpWLRDenoise = FullScreenPass::create(mpDevice, kWLRDenoiseShader);
    FALCOR_ASSERT(mpPackLinearZAndNormal && mpWLRDenoise);
}

Properties WLRPass::getProperties() const
{
    Properties props;
    props[kEnabled] = mFilterEnabled;
    props[kKernelRadius] = mKernelRadius;
    props[kSigmaSpatial] = mSigmaSpatial;
    props[kSigmaAlbedo] = mSigmaAlbedo;
    props[kSigmaDepth] = mSigmaDepth;
    props[kSigmaNormal] = mSigmaNormal;
    props[kMinWeight] = mMinWeight;
    props[kRegressionLambda] = mRegressionLambda;
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

RenderPassReflection WLRPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    reflector.addInput(kInputBufferAlbedo, "Albedo");
    reflector.addInput(kInputBufferColor, "Color");
    reflector.addInput(kInputBufferEmission, "Emission");
    reflector.addInput(kInputBufferWorldPosition, "World Position");
    reflector.addInput(kInputBufferWorldNormal, "World Normal");
    reflector.addInput(kInputBufferPosNormalFwidth, "PositionNormalFwidth");
    reflector.addInput(kInputBufferLinearZ, "LinearZ");
    reflector.addInput(kInputBufferMotionVector, "Motion vectors");

    reflector.addOutput(kOutputBufferFilteredImage, "Filtered image").format(ResourceFormat::RGBA32Float);

    return reflector;
}

void WLRPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    allocateFbos(compileData.defaultTexDims, pRenderContext);
    mBuffersNeedClear = true;
}

void WLRPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    ref<Texture> pAlbedoTexture = renderData.getTexture(kInputBufferAlbedo);
    ref<Texture> pColorTexture = renderData.getTexture(kInputBufferColor);
    ref<Texture> pEmissionTexture = renderData.getTexture(kInputBufferEmission);
    ref<Texture> pWorldPositionTexture = renderData.getTexture(kInputBufferWorldPosition);
    ref<Texture> pWorldNormalTexture = renderData.getTexture(kInputBufferWorldNormal);
    ref<Texture> pPosNormalFwidthTexture = renderData.getTexture(kInputBufferPosNormalFwidth);
    ref<Texture> pLinearZTexture = renderData.getTexture(kInputBufferLinearZ);
    ref<Texture> pMotionVectorTexture = renderData.getTexture(kInputBufferMotionVector);

    ref<Texture> pOutputTexture = renderData.getTexture(kOutputBufferFilteredImage);

    if (mBuffersNeedClear)
    {
        clearBuffers(pRenderContext, renderData);
        mBuffersNeedClear = false;
    }

    if (mFilterEnabled)
    {
        computeLinearZAndNormal(pRenderContext, pLinearZTexture, pWorldNormalTexture);
        computeWLRDenoise(pRenderContext, pColorTexture, pAlbedoTexture);

        // Blit into the output texture.
        pRenderContext->blit(mpPingPongFbo[1]->getColorTexture(0)->getSRV(), pOutputTexture->getRTV());
    }
    else
    {
        pRenderContext->blit(pColorTexture->getSRV(), pOutputTexture->getRTV());
    }

    mFrameCount += 1;
    std::swap(mpPingPongFbo[0], mpPingPongFbo[1]);
}

void WLRPass::allocateFbos(uint2 dim, RenderContext* pRenderContext)
{
    {
        // Screen-size RGBA32F buffer for linear Z, derivative, and packed normal
        Fbo::Desc desc;
        desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
        mpLinearZAndNormalFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
    }

    {
        // Screen-size FBOs with 1 RGBA32F buffer
        Fbo::Desc desc;
        desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
        mpFinalFbo = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
    }

    {
        // Screen-size FBOs with 1 RGBA32F buffer
        Fbo::Desc desc;
        desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
        // desc.setColorTarget(1, Falcor::ResourceFormat::RGBA32Float);
        // desc.setColorTarget(2, Falcor::ResourceFormat::RGBA32Float);
        // desc.setColorTarget(3, Falcor::ResourceFormat::RGBA32Float);
        // desc.setColorTarget(4, Falcor::ResourceFormat::RGBA32Float);
        // desc.setColorTarget(5, Falcor::ResourceFormat::RGBA32Float);
        // desc.setColorTarget(6, Falcor::ResourceFormat::RGBA32Float);
        mpPingPongFbo[0] = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
        mpPingPongFbo[1] = Fbo::create2D(mpDevice, dim.x, dim.y, desc);
    }

    mBuffersNeedClear = true;
}

void WLRPass::clearBuffers(RenderContext* pRenderContext, const RenderData& renderData)
{
    pRenderContext->clearFbo(mpLinearZAndNormalFbo.get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpPingPongFbo[0].get(), float4(0), 1.0f, 0, FboAttachmentType::All);
    pRenderContext->clearFbo(mpPingPongFbo[1].get(), float4(0), 1.0f, 0, FboAttachmentType::All);
}

// Extracts linear z and its derivative from the linear Z texture and packs
// the normal from the world normal texture and packes them into the FBO.
// (It's slightly wasteful to copy linear z here, but having this all
// together in a single buffer is a small simplification, since we make a
// copy of it to refer to in the next frame.)
void WLRPass::computeLinearZAndNormal(RenderContext* pRenderContext, ref<Texture> pLinearZTexture, ref<Texture> pWorldNormalTexture)
{
    auto perImageCB = mpPackLinearZAndNormal->getRootVar()["PerImageCB"];
    perImageCB["gLinearZ"] = pLinearZTexture;
    perImageCB["gNormal"] = pWorldNormalTexture;

    mpPackLinearZAndNormal->execute(pRenderContext, mpLinearZAndNormalFbo);
}

void WLRPass::computeWLRDenoise(RenderContext* pRenderContext, ref<Texture> pColorTexture, ref<Texture> pAlbedoTexture)
{
    auto perImageCB = mpWLRDenoise->getRootVar()["PerImageCB"];

    perImageCB["gColor"] = pColorTexture;
    perImageCB["gAlbedo"] = pAlbedoTexture;
    perImageCB["gLinearZAndNormal"] = mpLinearZAndNormalFbo->getColorTexture(0);

    // perImageCB["gPrevBeta1"] = mpPingPongFbo[0]->getColorTexture(0);
    // perImageCB["gPrevBeta2"] = mpPingPongFbo[0]->getColorTexture(1);
    // perImageCB["gPrevBeta3"] = mpPingPongFbo[0]->getColorTexture(2);
    // perImageCB["gPrevAlphaResidual"] = mpPingPongFbo[0]->getColorTexture(3);
    // perImageCB["gPrevColor"] = mpPingPongFbo[0]->getColorTexture(4);
    // perImageCB["gPrevAlbedo"] = mpPingPongFbo[0]->getColorTexture(5);
    // perImageCB["gPrevLinearZAndNormal"] = mpPingPongFbo[0]->getColorTexture(6);

    // perImageCB["eventThreshold"] = (mFrameCount == 0) ? 0.0f : 0.01f;
    // perImageCB["kernelRadius"] = mKernelRadius;
    // perImageCB["minWeight"] = mMinWeight;
    // perImageCB["ridgeLambda"] = mRegressionLambda;
    
    perImageCB["gKernelRadius"] = mKernelRadius;
    perImageCB["gSigmaSpatial"] = mSigmaSpatial;
    perImageCB["gSigmaAlbedo"] = mSigmaAlbedo;
    perImageCB["gSigmaDepth"] = mSigmaDepth;
    perImageCB["gSigmaNormal"] = mSigmaNormal;
    
    mpWLRDenoise->execute(pRenderContext, mpPingPongFbo[1]);

}

void WLRPass::renderUI(Gui::Widgets& widget)
{
    // int dirty = 0;
    // dirty |= (int)widget.checkbox("Enable WLR", mFilterEnabled);

    // widget.text("");
    // widget.text("Number of filter iterations.  Which");
    // widget.text("    iteration feeds into future frames?");
    // dirty |= (int)widget.var("Iterations", mFilterIterations, 2, 10, 1);
    // dirty |= (int)widget.var("Feedback", mFeedbackTap, -1, mFilterIterations - 2, 1);

    // widget.text("");
    // widget.text("Contol edge stopping on bilateral fitler");
    // dirty |= (int)widget.var("For Color", mPhiColor, 0.0f, 10000.0f, 0.01f);
    // dirty |= (int)widget.var("For Normal", mPhiNormal, 0.001f, 1000.0f, 0.2f);

    // widget.text("");
    // widget.text("How much history should be used?");
    // widget.text("    (alpha; 0 = full reuse; 1 = no reuse)");
    // dirty |= (int)widget.var("Alpha", mAlpha, 0.0f, 1.0f, 0.001f);
    // dirty |= (int)widget.var("Moments Alpha", mMomentsAlpha, 0.0f, 1.0f, 0.001f);

    // if (dirty)
    //     mBuffersNeedClear = true;
}
