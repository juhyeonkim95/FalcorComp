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
#include "../Shared/Host/InlinePassUtils.h"
#include "RenderGraph/RenderPass.h"

using namespace Falcor;

/** Frame-to-frame difference for event camera simulation (Kim et al., EGSR 2026, Sec. 4.2-4.3), non-motion-aligned.
 * - independent: one render per frame (color1); dI_t = I_t - I_{t-1}.
 * - correlated: two renders of the current frame, color1 with the previous frame's seed r_{t-1} and color2 with the
 *   current seed r_t; dI_t = I^1_t - I^2_{t-1}, the pair that shares r_{t-1}. Primal = (I^1_t + I^2_t) / 2.
 * dL_t = log(Ie + lum(new)) - log(Ie + lum(old)) for the same pair. The seeds are set on the tracers by the caller.
 * With subframes = N, N executions (scene held still) are averaged into one event frame; the outputs keep the last
 * event frame until the next one completes, and the dictionary key "eventFrameReady" tells EventGenerator.
 */
class EventDifference : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(EventDifference, "EventDifference", "Frame-to-frame difference (dI, dL) for event cameras.");
    static ref<EventDifference> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<EventDifference>(pDevice, props);
    }
    EventDifference(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;

    /// Forget the history: the next event frame has no difference (outputs 0).
    void reset();
    uint32_t getSubframe() const { return mSubframe; }
    uint32_t getEventFrame() const { return mEventFrame; }

private:
    struct Options
    {
        bool correlated = true;
        float intensityBias = 1e-8f;
        uint32_t subframes = 1;
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);

    Options mOptions;

    uint32_t mSubframe = 0;   ///< Index of the next execution within the event frame.
    uint32_t mEventFrame = 0; ///< Completed event frames since the last reset.
    ref<ComputePass> mpPass;
    ref<Texture> mpSum1, mpSum2, mpHistory, mpDeltaI, mpDeltaL, mpPrimal;
};

/** EventSVGF (Kim et al., EGSR 2026): denoises the frame difference from correlated sampling (color1 with the
 * previous frame's seed, color2 with the current one) with an extension of SVGF, and outputs the same channels as
 * EventDifference. Per frame:
 * 1. reproject: demodulate (i = (I - E) / A), accumulate the primal (I^1 + I^2) / 2 over time as SVGF does, and the
 *    non-motion-aligned difference I^1_t - I^2_{t-1} with the correction of Eq. 15-16;
 * 2. atrous: a-trous wavelet filter of both; the difference uses the difference-aware weight (Eq. 12), which also
 *    needs the previous frame's depth and normal to agree, and leaves out emitters;
 * 3. finalize: remodulate the difference (Eq. 19) and convert it to the brightness change (Eq. 21).
 * Luminance only: deltaI holds dI in all three channels; primal is albedo * illumination + emission.
 */
class EventSVGF : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(EventSVGF, "EventSVGF", "Difference-aware SVGF for event cameras.");
    static ref<EventSVGF> create(ref<Device> pDevice, const Properties& props) { return make_ref<EventSVGF>(pDevice, props); }
    EventSVGF(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;

    /// Forget the history: the next frame has no difference (outputs 0).
    void reset() { mFrameCount = 0; mClearHistory = true; }

private:
    struct Options
    {
        uint32_t iterations = 4;
        int32_t feedbackTap = 1; ///< a-trous iteration fed back to the next frame (-1: the unfiltered accumulation).
        float phiColor = 10.f;
        float phiNormal = 128.f;
        float alpha = 0.1f;
        float momentsAlpha = 0.2f;
        float intensityBias = 1e-8f;
        bool useDemodulation = true;
        bool useDifferenceAwareFiltering = true;
        bool useTemporalAccumulation = true;
        bool useDenoisedDifference = true;
        bool useDifferenceVariance = true; ///< The difference's own variance sets its edge-stopping width.
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);
    void allocate(uint2 dim);
    void clearHistory(RenderContext* pRenderContext);

    Options mOptions;

    uint32_t mFrameCount = 0;
    bool mClearHistory = true;
    uint2 mDim = uint2(0);
    ref<ComputePass> mpReproject, mpFilterMoments, mpAtrous, mpFinalize;
    // History: [0] the current frame, [1] the previous one; swapped every frame.
    ref<Texture> mpZN[2], mpMoments[2], mpHistory[2], mpReprojected[2];
    ref<Texture> mpPrevFiltered, mpPrevPrevFiltered; ///< Feedback-tap illumination of frames t-1 and t-2.
    ref<Texture> mpPrevIllumination2, mpPrevAlbedoEmission, mpPrevFinalIllumination;
    ref<Texture> mpIllumination, mpPingPong[2];
    ref<Texture> mpEmitter; ///< Emitter in the current or the previous frame (R8).
};

/** Events from the brightness change dL of each event frame; output is the signed event count per pixel.
 * - probabilistic: floor(|dL|/C) events plus one more with probability frac(|dL|/C), with the sign of dL (the
 *   threshold phase is uniform, Kim et al. Sec. 4.6 and App. B).
 * - accumulate: per-pixel residual r = L - L_ref; r += dL, n = trunc(r / C), r -= n C (Eq. 22).
 */
class EventGenerator : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(EventGenerator, "EventGenerator", "Event generation from brightness change.");
    static ref<EventGenerator> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<EventGenerator>(pDevice, props);
    }
    EventGenerator(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;

    /// Clear the residuals (accumulate) and the frame counter.
    void reset();

    enum class Mode { Probabilistic = 0, Accumulate = 1 };

private:
    struct Options
    {
        Mode mode = Mode::Probabilistic;
        float threshold = 0.2f;
        uint32_t seed = 0;
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);

    Options mOptions;

    uint32_t mFrame = 0;
    bool mClearResidual = true;
    ref<ComputePass> mpPass;
    ref<Texture> mpResidual, mpEvents;
};
