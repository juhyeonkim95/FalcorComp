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
#include "EventCamera.h"
#include "RenderGraph/RenderPassHelpers.h"

static void regEventCamera(pybind11::module& m)
{
    pybind11::class_<EventDifference, RenderPass, ref<EventDifference>> difference(m, "EventDifference");
    difference.def("reset", &EventDifference::reset);
    difference.def_property_readonly("subframe", &EventDifference::getSubframe);
    difference.def_property_readonly("event_frame", &EventDifference::getEventFrame);

    pybind11::class_<EventGenerator, RenderPass, ref<EventGenerator>> generator(m, "EventGenerator");
    generator.def("reset", &EventGenerator::reset);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, EventDifference>();
    registry.registerClass<RenderPass, EventGenerator>();
    ScriptBindings::registerBinding(regEventCamera);
}

namespace
{
const char kDifferenceShader[] = "RenderPasses/EventCamera/EventDifference.cs.slang";
const char kGeneratorShader[] = "RenderPasses/EventCamera/EventGenerator.cs.slang";
const char kEventFrameReady[] = "eventFrameReady";

const ChannelList kDifferenceInputs = {
    { "color1", "gColor1", "Render of the current frame (correlated: with the previous frame's seed)", false },
    { "color2", "gColor2", "correlated: render of the current frame with the current seed", true },
};
const ChannelList kDifferenceOutputs = {
    { "deltaI", "", "Intensity change dI of the last event frame (RGB)", false, ResourceFormat::RGBA32Float },
    { "deltaL", "", "Brightness change dL = d log(Ie + luminance) of the last event frame", false, ResourceFormat::R32Float },
    { "primal", "", "Intensity of the last event frame", false, ResourceFormat::RGBA32Float },
};
const ChannelList kGeneratorInputs = {
    { "deltaL", "gDeltaL", "Brightness change of the event frame", false },
};
const ChannelList kGeneratorOutputs = {
    { "events", "", "Signed event count of the last event frame", false, ResourceFormat::R32Float },
};

ref<Texture> ensureTexture(ref<Device> pDevice, ref<Texture> pTexture, uint2 dim, ResourceFormat format, bool& created)
{
    if (pTexture && pTexture->getWidth() == dim.x && pTexture->getHeight() == dim.y)
        return pTexture;
    created = true;
    return pDevice->createTexture2D(dim.x, dim.y, format, 1, 1, nullptr,
        ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
}
} // namespace

// EventDifference

EventDifference::EventDifference(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == "sampling")
        {
            const std::string sampling = value;
            if (sampling != "independent" && sampling != "correlated")
                FALCOR_THROW("sampling must be independent or correlated.");
            mCorrelated = sampling == "correlated";
        }
        else if (key == "intensityBias")
            mIntensityBias = value;
        else if (key == "subframes")
            mSubframes = value;
        else
            logWarning("Unknown property '{}' in EventDifference properties.", key);
    }
    if (mSubframes < 1)
        FALCOR_THROW("subframes must be at least 1.");
    if (!(mIntensityBias > 0.f))
        FALCOR_THROW("intensityBias must be positive.");
    mpPass = ComputePass::create(mpDevice, kDifferenceShader, "main");
}

Properties EventDifference::getProperties() const
{
    Properties props;
    props["sampling"] = mCorrelated ? "correlated" : "independent";
    props["intensityBias"] = mIntensityBias;
    props["subframes"] = mSubframes;
    return props;
}

RenderPassReflection EventDifference::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kDifferenceInputs);
    addRenderPassOutputs(reflector, kDifferenceOutputs);
    return reflector;
}

void EventDifference::reset()
{
    mSubframe = 0;
    mEventFrame = 0;
}

void EventDifference::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const ref<Texture> pColor1 = renderData.getTexture("color1");
    const ref<Texture> pColor2 = renderData.getTexture("color2");
    if (mCorrelated && !pColor2)
        FALCOR_THROW("EventDifference: sampling 'correlated' needs the input color2.");

    const uint2 dim = uint2(pColor1->getWidth(), pColor1->getHeight());
    bool created = false;
    mpSum1 = ensureTexture(mpDevice, mpSum1, dim, ResourceFormat::RGBA32Float, created);
    mpSum2 = ensureTexture(mpDevice, mpSum2, dim, ResourceFormat::RGBA32Float, created);
    mpHistory = ensureTexture(mpDevice, mpHistory, dim, ResourceFormat::RGBA32Float, created);
    mpDeltaI = ensureTexture(mpDevice, mpDeltaI, dim, ResourceFormat::RGBA32Float, created);
    mpDeltaL = ensureTexture(mpDevice, mpDeltaL, dim, ResourceFormat::R32Float, created);
    mpPrimal = ensureTexture(mpDevice, mpPrimal, dim, ResourceFormat::RGBA32Float, created);
    if (created)
    {
        reset();
        pRenderContext->clearUAV(mpDeltaI->getUAV().get(), float4(0.f));
        pRenderContext->clearUAV(mpDeltaL->getUAV().get(), float4(0.f));
        pRenderContext->clearUAV(mpPrimal->getUAV().get(), float4(0.f));
    }

    auto var = mpPass->getRootVar();
    var["CB"]["gFrameDim"] = dim;
    var["CB"]["gSubframe"] = mSubframe;
    var["CB"]["gSubframes"] = mSubframes;
    var["CB"]["gCorrelated"] = uint(mCorrelated);
    var["CB"]["gHasHistory"] = uint(mEventFrame > 0);
    var["CB"]["gIntensityBias"] = mIntensityBias;
    var["gColor1"] = pColor1;
    var["gColor2"] = mCorrelated ? pColor2 : pColor1;
    var["gSum1"] = mpSum1;
    var["gSum2"] = mpSum2;
    var["gHistory"] = mpHistory;
    var["gDeltaI"] = mpDeltaI;
    var["gDeltaL"] = mpDeltaL;
    var["gPrimal"] = mpPrimal;
    mpPass->execute(pRenderContext, uint3(dim, 1));

    const bool ready = mSubframe + 1 == mSubframes;
    mSubframe = ready ? 0 : mSubframe + 1;
    if (ready)
        mEventFrame++;
    renderData.getDictionary()[kEventFrameReady] = ready;

    // The outputs keep the last complete event frame.
    pRenderContext->copyResource(renderData.getTexture("deltaI").get(), mpDeltaI.get());
    pRenderContext->copyResource(renderData.getTexture("deltaL").get(), mpDeltaL.get());
    pRenderContext->copyResource(renderData.getTexture("primal").get(), mpPrimal.get());
}

// EventGenerator

EventGenerator::EventGenerator(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == "mode")
        {
            const std::string mode = value;
            if (mode == "probabilistic")
                mMode = Mode::Probabilistic;
            else if (mode == "accumulate")
                mMode = Mode::Accumulate;
            else
                FALCOR_THROW("mode must be probabilistic or accumulate.");
        }
        else if (key == "threshold")
            mThreshold = value;
        else if (key == "seed")
            mSeed = value;
        else
            logWarning("Unknown property '{}' in EventGenerator properties.", key);
    }
    if (!(mThreshold > 0.f))
        FALCOR_THROW("threshold must be positive.");
    mpPass = ComputePass::create(mpDevice, kGeneratorShader, "main");
}

Properties EventGenerator::getProperties() const
{
    Properties props;
    props["mode"] = mMode == Mode::Probabilistic ? "probabilistic" : "accumulate";
    props["threshold"] = mThreshold;
    props["seed"] = mSeed;
    return props;
}

RenderPassReflection EventGenerator::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kGeneratorInputs);
    addRenderPassOutputs(reflector, kGeneratorOutputs);
    return reflector;
}

void EventGenerator::reset()
{
    mFrame = 0;
    mClearResidual = true;
}

void EventGenerator::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const ref<Texture> pDeltaL = renderData.getTexture("deltaL");
    const uint2 dim = uint2(pDeltaL->getWidth(), pDeltaL->getHeight());
    bool created = false;
    mpResidual = ensureTexture(mpDevice, mpResidual, dim, ResourceFormat::R32Float, created);
    mpEvents = ensureTexture(mpDevice, mpEvents, dim, ResourceFormat::R32Float, created);
    if (created)
    {
        reset();
        pRenderContext->clearUAV(mpEvents->getUAV().get(), float4(0.f));
    }

    // Only once per event frame: EventDifference may average several executions into one.
    const bool ready = renderData.getDictionary().getValue(kEventFrameReady, true);
    if (ready)
    {
        auto var = mpPass->getRootVar();
        var["CB"]["gFrameDim"] = dim;
        var["CB"]["gMode"] = uint(mMode);
        var["CB"]["gThreshold"] = mThreshold;
        var["CB"]["gFrame"] = mFrame;
        var["CB"]["gSeed"] = mSeed;
        var["CB"]["gClearResidual"] = uint(mClearResidual);
        var["gDeltaL"] = pDeltaL;
        var["gResidual"] = mpResidual;
        var["gEvents"] = mpEvents;
        mpPass->execute(pRenderContext, uint3(dim, 1));
        mFrame++;
        mClearResidual = false;
    }
    pRenderContext->copyResource(renderData.getTexture("events").get(), mpEvents.get());
}
