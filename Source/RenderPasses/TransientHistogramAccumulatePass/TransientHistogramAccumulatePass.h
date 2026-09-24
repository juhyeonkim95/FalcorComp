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

using namespace Falcor;

/** Averages a transient histogram (width x height x bins, R32Float or RGBA32Float) over frames: the 3D
 * counterpart of AccumulatePass. The output has the input's shape and holds the running mean. With autoReset,
 * the average restarts when the camera moves, the scene changes or an upstream pass changes its options.
 * The number of averaged frames is published in the render data dictionary
 * (TransientHistogramConfig::kFrameCountKey).
 */
class TransientHistogramAccumulatePass : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TransientHistogramAccumulatePass, "TransientHistogramAccumulatePass", "Average a transient histogram over frames.");

    static ref<TransientHistogramAccumulatePass> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TransientHistogramAccumulatePass>(pDevice, props);
    }

    TransientHistogramAccumulatePass(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

    /// Restarts the average.
    void reset() { mFrameCount = 0; }

private:
    enum class Precision : uint32_t
    {
        Single = 0,           ///< Running mean in float.
        SingleCompensated = 1 ///< Running mean in float with Kahan summation (one more histogram-sized buffer).
    };

    /// The input's shape and format as far as the graph knows them (defaults where it does not yet).
    static std::pair<uint3, ResourceFormat> inputShape(const CompileData& compileData);
    bool needsAutoReset(const RenderData& renderData) const;
    void prepareState(const ref<Texture>& pInput);

    bool mEnabled = true;       ///< Off: the output is the input.
    bool mAutoReset = true;
    Precision mPrecision = Precision::Single;
    uint mMaxFrameCount = 0;    ///< Stop averaging after this many frames; 0 = no limit.

    uint mFrameCount = 0;       ///< Frames in the current average.
    std::pair<uint3, ResourceFormat> mDeclaredShape; ///< Output shape declared by the last reflect().
    ref<Scene> mpScene;
    ref<Texture> mpMean;
    ref<Texture> mpCompensation;
    ref<ComputePass> mpPass;
};
