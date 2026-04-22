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
#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Core/Pass/FullScreenPass.h"

using namespace Falcor;

class WLRPass : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(WLRPass, "WLRPass", "WLR denoising pass.");

    static ref<WLRPass> create(ref<Device> pDevice, const Properties& props) { return make_ref<WLRPass>(pDevice, props); }

    WLRPass(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    virtual void renderUI(Gui::Widgets& widget) override;

private:
    void allocateFbos(uint2 dim, RenderContext* pRenderContext);
    void clearBuffers(RenderContext* pRenderContext, const RenderData& renderData);

    void computeLinearZAndNormal(RenderContext* pRenderContext, ref<Texture> pLinearZTexture, ref<Texture> pWorldNormalTexture);
    void computeWLRDenoise(RenderContext* pRenderContext, ref<Texture> pColorTexture, ref<Texture> pAlbedoTexture);

    bool mBuffersNeedClear = false;

    // WLR parameters
    bool mFilterEnabled = true;
    int32_t mKernelRadius = 2;
    float mSigmaSpatial = 2;
    float mSigmaAlbedo = 0.20;
    float mSigmaDepth = 0.05;
    float mSigmaNormal = 0.20f;
    float mMinWeight = 1e-6f;
    float mRegressionLambda = 1e-4f;

    // WLR passes
    ref<FullScreenPass> mpPackLinearZAndNormal;
    ref<FullScreenPass> mpWLRDenoise;

    // Intermediate framebuffers
    ref<Fbo> mpPingPongFbo[2];
    ref<Fbo> mpLinearZAndNormalFbo;
    ref<Fbo> mpFinalFbo;

    uint mFrameCount = 0;
};
