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
#include "TransientHistogramViewer.h"
#include "RenderGraph/RenderPassHelpers.h"
#include <algorithm>
#include <cmath>

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TransientHistogramViewer>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/TransientHistogramViewer/TransientHistogramViewer.cs.slang";

const char kInput[] = "histogram";
const char kOutput[] = "output";

const char kFirstBin[] = "firstBin";
const char kLastBin[] = "lastBin";
const char kBinExposure[] = "binExposure";

// Published by TransientHistogramPathTracerInline.
const char kHistogramFrameCount[] = "transientHistogramFrameCount";
const char kHistogramTimeMin[] = "transientHistogramTimeMin";
const char kHistogramTimeMax[] = "transientHistogramTimeMax";
} // namespace

TransientHistogramViewer::TransientHistogramViewer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kFirstBin)
            mFirstBin = value;
        else if (key == kLastBin)
            mLastBin = value;
        else if (key == kBinExposure)
            mBinExposure = value;
        else
            logWarning("Unknown property '{}' in TransientHistogramViewer properties.", key);
    }
}

Properties TransientHistogramViewer::getProperties() const
{
    Properties props;
    props[kFirstBin] = mFirstBin;
    props[kLastBin] = mLastBin;
    props[kBinExposure] = mBinExposure;
    return props;
}

RenderPassReflection TransientHistogramViewer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    reflector.addInput(kInput, "Transient histogram (width x height x bins)").texture3D(0, 0, 0);
    reflector.addOutput(kOutput, "Sum image (left) and 4x4 grid of bins (right)")
        .format(ResourceFormat::RGBA32Float)
        .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    return reflector;
}

uint TransientHistogramViewer::tileBin(uint tile, uint binCount) const
{
    const int last = mLastBin < 0 ? int(binCount) + mLastBin : mLastBin;
    const int first = std::min(int(mFirstBin), int(binCount) - 1);
    const int end = std::clamp(last, first, int(binCount) - 1);
    return uint(first + std::lround(float(tile) * float(end - first) / float(kTileCount - 1)));
}

void TransientHistogramViewer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const ref<Texture> pHistogram = renderData.getTexture(kInput);
    const ref<Texture> pOutput = renderData.getTexture(kOutput);
    const uint3 histogramDim = {pHistogram->getWidth(), pHistogram->getHeight(), pHistogram->getDepth()};
    const uint2 outputDim = {pOutput->getWidth(), pOutput->getHeight()};

    // Normalize the accumulated histogram. Without producer metadata, assume one frame and unit bins.
    auto& dict = renderData.getDictionary();
    mBinCount = histogramDim.z;
    mFrameCount = std::max(1u, dict.getValue(kHistogramFrameCount, 1u));
    mTimeMin = dict.getValue(kHistogramTimeMin, 0.f);
    mTimeMax = dict.getValue(kHistogramTimeMax, float(mBinCount));
    const float range = mTimeMax - mTimeMin;

    DefineList defines;
    defines.add("SINGLE_CHANNEL", getFormatChannelCount(pHistogram->getFormat()) == 1 ? "1" : "0");
    if (!mpViewPass)
        mpViewPass = ComputePass::create(mpDevice, kShaderFile, "main", defines);
    mpViewPass->getProgram()->addDefines(defines);

    auto var = mpViewPass->getRootVar();
    var["CB"]["gOutputDim"] = outputDim;
    var["CB"]["gHistogramDim"] = histogramDim;
    var["CB"]["gSumScale"] = range / float(mBinCount) / float(mFrameCount);
    // A bin shown at the sum's brightness when all radiance arrives within it spread over the range.
    var["CB"]["gTileScale"] = range / float(mFrameCount) * std::exp2(mBinExposure);
    for (uint row = 0; row < 4; ++row)
    {
        var["CB"]["gTileBins"][row] = uint4(tileBin(4 * row, mBinCount), tileBin(4 * row + 1, mBinCount),
                                            tileBin(4 * row + 2, mBinCount), tileBin(4 * row + 3, mBinCount));
    }
    var["gHistogram"] = pHistogram;
    var["gOutput"] = pOutput;
    mpViewPass->execute(pRenderContext, uint3(outputDim, 1));
}

void TransientHistogramViewer::renderUI(Gui::Widgets& widget)
{
    const uint lastIndex = mBinCount > 0 ? mBinCount - 1 : 0;
    widget.var("First bin", mFirstBin, 0u, lastIndex);
    widget.tooltip("Bin shown in the top-left tile.", true);

    uint lastBin = mBinCount > 0 ? tileBin(kTileCount - 1, mBinCount) : 0;
    if (widget.var("Last bin", lastBin, 0u, lastIndex))
        mLastBin = lastBin == lastIndex ? -1 : int(lastBin);
    widget.tooltip("Bin shown in the bottom-right tile. The 16 tiles are spread evenly from First bin to Last "
                   "bin, in reading order.", true);

    widget.var("Bin exposure (stops)", mBinExposure, -20.f, 20.f, 0.5f);
    widget.tooltip("Brightens the grid tiles relative to the sum image. At 0, a tile is as bright as the sum "
                   "when the pixel's light is spread evenly over the histogram range.", true);

    if (mBinCount == 0)
        return;
    widget.text(fmt::format("Accumulated frames: {}", mFrameCount));
    const float binWidth = (mTimeMax - mTimeMin) / float(mBinCount);
    if (auto group = widget.group("Tile bins"))
    {
        for (uint tile = 0; tile < kTileCount; ++tile)
        {
            const uint bin = tileBin(tile, mBinCount);
            const float start = mTimeMin + float(bin) * binWidth;
            group.text(fmt::format("Row {} col {}: bin {} [{:.3f}, {:.3f})", tile / 4 + 1, tile % 4 + 1, bin, start,
                                   start + binWidth));
        }
    }
}
