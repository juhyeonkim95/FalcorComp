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
const char kOverlay[] = "overlay";
const char kOutput[] = "output";

const char kFirstBin[] = "firstBin";
const char kLastBin[] = "lastBin";
const char kBinExposure[] = "binExposure";
const char kLeftView[] = "leftView"; // "sum" or "bin"
const char kLeftBin[] = "leftBin";
const char kSelectedPixel[] = "selectedPixel";
const char kProfileRadius[] = "profileRadius";

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
        else if (key == kLeftView)
        {
            const std::string view = value;
            if (view != "sum" && view != "bin")
                FALCOR_THROW("leftView must be sum or bin.");
            mLeftShowsBin = view == "bin";
        }
        else if (key == kLeftBin)
            mLeftBin = value;
        else if (key == kSelectedPixel)
            mSelectedPixel = value;
        else if (key == kProfileRadius)
            mProfileRadius = value;
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
    props[kLeftView] = mLeftShowsBin ? "bin" : "sum";
    props[kLeftBin] = mLeftBin;
    props[kSelectedPixel] = mSelectedPixel;
    props[kProfileRadius] = mProfileRadius;
    return props;
}

RenderPassReflection TransientHistogramViewer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    reflector.addInput(kInput, "Transient histogram (width x height x bins)").texture3D(0, 0, 0);
    reflector.addInput(kOverlay, "Overlay for the sum image: histogram-sized, premultiplied alpha")
        .flags(RenderPassReflection::Field::Flags::Optional);
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
    mOutputDim = outputDim;
    mHistogramDim = histogramDim.xy();
    if (any(mSelectedPixel >= int2(mHistogramDim)))
        mSelectedPixel = {-1, -1};

    // Normalize the accumulated histogram. Without producer metadata, assume one frame and unit bins.
    auto& dict = renderData.getDictionary();
    mBinCount = histogramDim.z;
    mFrameCount = std::max(1u, dict.getValue(kHistogramFrameCount, 1u));
    mTimeMin = dict.getValue(kHistogramTimeMin, 0.f);
    mTimeMax = dict.getValue(kHistogramTimeMax, float(mBinCount));
    const float range = mTimeMax - mTimeMin;

    // The overlay is used only when it has the histogram's size.
    const ref<Texture> pOverlay = renderData.getTexture(kOverlay);
    const bool hasOverlay = pOverlay && pOverlay->getWidth() == histogramDim.x && pOverlay->getHeight() == histogramDim.y;
    if (pOverlay && !hasOverlay)
        logWarning("TransientHistogramViewer: the overlay must be {}x{}; it is ignored.", histogramDim.x, histogramDim.y);

    DefineList defines;
    defines.add("SINGLE_CHANNEL", getFormatChannelCount(pHistogram->getFormat()) == 1 ? "1" : "0");
    defines.add("HAS_OVERLAY", hasOverlay ? "1" : "0");
    if (!mpViewPass)
        mpViewPass = ComputePass::create(mpDevice, kShaderFile, "main", defines);
    mpViewPass->getProgram()->addDefines(defines);
    if (!mpProfilePass)
        mpProfilePass = ComputePass::create(mpDevice, kShaderFile, "readProfile", defines);
    mpProfilePass->getProgram()->addDefines(defines);

    auto var = mpViewPass->getRootVar();
    var["CB"]["gOutputDim"] = outputDim;
    var["CB"]["gHistogramDim"] = histogramDim;
    var["CB"]["gSumScale"] = range / float(mBinCount) / float(mFrameCount);
    // A bin shown at the sum's brightness when all radiance arrives within it spread over the range.
    var["CB"]["gTileScale"] = range / float(mFrameCount) * std::exp2(mBinExposure);
    var["CB"]["gLeftBin"] = mLeftShowsBin ? std::min(mLeftBin, mBinCount - 1) : ~0u;
    for (uint row = 0; row < 4; ++row)
    {
        var["CB"]["gTileBins"][row] = uint4(tileBin(4 * row, mBinCount), tileBin(4 * row + 1, mBinCount),
                                            tileBin(4 * row + 2, mBinCount), tileBin(4 * row + 3, mBinCount));
    }
    var["CB"]["gSelectedPixel"] = mSelectedPixel;
    var["gHistogram"] = pHistogram;
    if (hasOverlay)
        var["gOverlay"] = pOverlay;
    var["gOutput"] = pOutput;
    mpViewPass->execute(pRenderContext, uint3(outputDim, 1));

    if (all(mSelectedPixel >= 0))
        readProfile(pRenderContext, pHistogram, 1.f / float(mFrameCount));
    else
        mProfile.clear();
}

void TransientHistogramViewer::readProfile(RenderContext* pRenderContext, const ref<Texture>& pHistogram, float frameScale)
{
    // The profile is read back asynchronously, so the plot lags the image by a frame or two
    // instead of stalling on the GPU every frame.
    if (!mpProfileFence)
        mpProfileFence = mpDevice->createFence();
    if (mProfilePendingValue != 0)
    {
        if (mpProfileFence->getCurrentValue() < mProfilePendingValue)
            return; // The previous copy is still in flight.
        const float4* pData = static_cast<const float4*>(mpProfileReadback->map());
        mProfile.assign(pData, pData + mpProfileReadback->getSize() / sizeof(float4));
        mpProfileReadback->unmap();
        mProfilePendingValue = 0;
    }

    if (!mpProfileBuffer || mpProfileBuffer->getElementCount() != mBinCount)
    {
        mpProfileBuffer = mpDevice->createStructuredBuffer(
            sizeof(float4), mBinCount, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            MemoryType::DeviceLocal, nullptr, false
        );
        mpProfileReadback = mpDevice->createBuffer(sizeof(float4) * mBinCount, ResourceBindFlags::None, MemoryType::ReadBack);
    }
    auto var = mpProfilePass->getRootVar();
    var["CB"]["gHistogramDim"] = uint3(mHistogramDim, mBinCount);
    var["CB"]["gSelectedPixel"] = mSelectedPixel;
    var["CB"]["gProfileRadius"] = mProfileRadius;
    var["CB"]["gProfileScale"] = frameScale;
    var["gHistogram"] = pHistogram;
    var["gProfile"] = mpProfileBuffer;
    mpProfilePass->execute(pRenderContext, uint3(mBinCount, 1, 1));
    pRenderContext->copyResource(mpProfileReadback.get(), mpProfileBuffer.get());
    mProfilePendingValue = pRenderContext->signal(mpProfileFence.get());
}

bool TransientHistogramViewer::outputToHistogram(float2 position, int2& pixel) const
{
    // Mirrors fitPanel() and the tile layout in the shader.
    if (mHistogramDim.x == 0 || mOutputDim.x == 0)
        return false;
    const float2 histogramSize = float2(mHistogramDim);
    const float halfWidth = 0.5f * float(mOutputDim.x);
    float2 origin = {0.f, 0.f};
    float2 size = {halfWidth, float(mOutputDim.y)};
    if (position.x >= halfWidth)
    {
        const float2 tileSize = size / 4.f;
        const float2 tile = min(floor((position - float2(halfWidth, 0.f)) / tileSize), float2(3.f));
        origin = float2(halfWidth, 0.f) + tile * tileSize + 1.f;
        size = tileSize - 1.f;
    }
    const float scale = std::min(size.x / histogramSize.x, size.y / histogramSize.y);
    const float2 offset = origin + 0.5f * (size - scale * histogramSize);
    const float2 coordinate = floor((position - offset) / scale);
    if (any(coordinate < 0.f) || any(coordinate >= histogramSize))
        return false;
    pixel = int2(coordinate);
    return true;
}

bool TransientHistogramViewer::onMouseEvent(const MouseEvent& mouseEvent)
{
    const float2 position = mouseEvent.pos * float2(mOutputDim);
    switch (mouseEvent.type)
    {
    case MouseEvent::Type::ButtonDown:
        if (mouseEvent.button == Input::MouseButton::Left && is_set(mouseEvent.mods, Input::ModifierFlags::Shift))
        {
            mPicking = true;
            outputToHistogram(position, mSelectedPixel);
            return true;
        }
        return false;
    case MouseEvent::Type::Move:
        if (mPicking)
        {
            outputToHistogram(position, mSelectedPixel);
            return true;
        }
        return false;
    case MouseEvent::Type::ButtonUp:
        if (mPicking && mouseEvent.button == Input::MouseButton::Left)
        {
            mPicking = false;
            return true;
        }
        return false;
    default:
        return false;
    }
}

void TransientHistogramViewer::renderUI(Gui::Widgets& widget)
{
    const uint lastIndex = mBinCount > 0 ? mBinCount - 1 : 0;
    static const Gui::DropdownList kLeftViewList = {{0, "Sum over bins"}, {1, "One bin"}};
    uint32_t leftView = mLeftShowsBin ? 1 : 0;
    if (widget.dropdown("Left half", kLeftViewList, leftView))
        mLeftShowsBin = leftView == 1;
    widget.tooltip("Sum over bins: the light arriving within the histogram range. One bin: the chosen bin, as bright "
                   "as a tile.", true);
    if (mLeftShowsBin)
    {
        widget.var("Left bin", mLeftBin, 0u, lastIndex);
        if (mBinCount > 0)
        {
            const float binWidth = (mTimeMax - mTimeMin) / float(mBinCount);
            const float start = mTimeMin + float(std::min(mLeftBin, lastIndex)) * binWidth;
            widget.text(fmt::format("Path length [{:.3f}, {:.3f})", start, start + binWidth));
        }
    }

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
    renderProfileUI(widget);
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

void TransientHistogramViewer::renderProfileUI(Gui::Widgets& widget)
{
    auto group = widget.group("Transient profile", true);
    if (!group)
        return;
    if (all(mSelectedPixel < 0) || mProfile.size() != mBinCount)
    {
        group.text("Shift+click (or drag) on the image to pick a pixel.");
        return;
    }

    group.text(fmt::format("Pixel ({}, {})", mSelectedPixel.x, mSelectedPixel.y));
    group.var("Patch radius", mProfileRadius, 0u, 16u);
    group.tooltip("Average the profile over a (2r + 1) x (2r + 1) patch around the pixel to reduce noise.", true);

    static const Gui::DropdownList kChannelList = {
        {(uint32_t)ProfileChannel::Luminance, "Luminance"},
        {(uint32_t)ProfileChannel::Red, "Red"},
        {(uint32_t)ProfileChannel::Green, "Green"},
        {(uint32_t)ProfileChannel::Blue, "Blue"},
    };
    uint32_t channel = (uint32_t)mProfileChannel;
    if (group.dropdown("Channel", kChannelList, channel))
        mProfileChannel = (ProfileChannel)channel;

    mPlotValues.resize(mProfile.size());
    for (size_t bin = 0; bin < mProfile.size(); ++bin)
    {
        const float3 value = mProfile[bin].xyz();
        switch (mProfileChannel)
        {
        case ProfileChannel::Red: mPlotValues[bin] = value.x; break;
        case ProfileChannel::Green: mPlotValues[bin] = value.y; break;
        case ProfileChannel::Blue: mPlotValues[bin] = value.z; break;
        default: mPlotValues[bin] = dot(value, float3(0.2126f, 0.7152f, 0.0722f)); break; // Rec. 709, as in the shaders
        }
    }
    const auto peak = std::max_element(mPlotValues.begin(), mPlotValues.end());
    const uint peakBin = uint(peak - mPlotValues.begin());
    const float binWidth = (mTimeMax - mTimeMin) / float(mBinCount);
    float total = 0.f;
    for (float value : mPlotValues)
        total += value * binWidth;

    auto plotValue = [](void* pData, int32_t index) { return (*static_cast<std::vector<float>*>(pData))[index]; };
    group.graph("##profile", plotValue, &mPlotValues, uint32_t(mPlotValues.size()), 0, 0.f, FLT_MAX, 0, 160);
    group.tooltip("Radiance per unit path length in each bin (x: bins from Range min to Range max).", true);
    group.text(fmt::format("x: path length {:.3f} to {:.3f}", mTimeMin, mTimeMax));
    group.text(fmt::format("Peak {:.4g} at bin {} (path length {:.3f})", *peak, peakBin,
                           mTimeMin + (float(peakBin) + 0.5f) * binWidth));
    group.text(fmt::format("Integrated over the range: {:.4g}", total));
    if (group.button("Clear selection"))
    {
        mSelectedPixel = {-1, -1};
        mProfile.clear();
    }
}
