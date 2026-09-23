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

/** Displays a transient histogram (W x H x B volume) in one image.
 *
 * Left half: the histogram summed over all bins (the steady-state image).
 * Right half: a 4 x 4 grid of 16 bins spread evenly from firstBin to lastBin, in reading order.
 * Both halves are fitted to their area with box filtering. The histogram is divided by the
 * frame count its producer publishes (TransientHistogramPathTracerInline accumulates across frames).
 */
class TransientHistogramViewer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(TransientHistogramViewer, "TransientHistogramViewer", "Show a transient histogram as its sum and a 4x4 grid of bins.");

    static ref<TransientHistogramViewer> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<TransientHistogramViewer>(pDevice, props);
    }

    TransientHistogramViewer(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;

private:
    static constexpr uint kTileCount = 16;

    /// Histogram bin shown in grid tile `tile` for a histogram with `binCount` bins.
    uint tileBin(uint tile, uint binCount) const;

    uint mFirstBin = 0;
    int mLastBin = -1;         ///< Last bin shown in the grid; negative counts from the end (-1 = last bin).
    float mBinExposure = 0.f;  ///< Extra exposure of the grid tiles, in stops.

    // Last histogram seen, for the UI.
    uint mBinCount = 0;
    uint mFrameCount = 0;
    float mTimeMin = 0.f;
    float mTimeMax = 0.f;

    ref<ComputePass> mpViewPass;
};
