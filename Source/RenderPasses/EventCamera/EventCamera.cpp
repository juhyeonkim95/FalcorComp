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

    pybind11::class_<EventSVGF, RenderPass, ref<EventSVGF>> svgf(m, "EventSVGF");
    svgf.def("reset", &EventSVGF::reset);

    pybind11::class_<EventGenerator, RenderPass, ref<EventGenerator>> generator(m, "EventGenerator");
    generator.def("reset", &EventGenerator::reset);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, EventDifference>();
    registry.registerClass<RenderPass, EventSVGF>();
    registry.registerClass<RenderPass, EventGenerator>();
    ScriptBindings::registerBinding(regEventCamera);
}

namespace
{
const char kDifferenceShader[] = "RenderPasses/EventCamera/EventDifference.cs.slang";
const char kSVGFShader[] = "RenderPasses/EventCamera/EventSVGF.cs.slang";
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
const ChannelList kSVGFInputs = {
    { "color1", "", "Render of the current frame with the previous frame's seed", false },
    { "color2", "", "Render of the current frame with the current seed", false },
    { "albedo", "", "Albedo of the primary hit", false },
    { "emission", "", "Emission of the primary hit", false },
    { "linearZ", "", "Linear z and its slope", false },
    { "normal", "", "World-space normal of the primary hit", false },
    { "mvec", "", "Motion vectors", false },
};
const ChannelList kSVGFOutputs = {
    { "deltaI", "", "Intensity change dI (luminance, in all three channels)", false, ResourceFormat::RGBA32Float },
    { "deltaL", "", "Brightness change dL = d log(Ie + luminance)", false, ResourceFormat::R32Float },
    { "primal", "", "Denoised intensity: albedo * illumination + emission", false, ResourceFormat::RGBA32Float },
    { "deltaIllumination", "", "Denoised demodulated difference di", false, ResourceFormat::R32Float },
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

// EventSVGF

EventSVGF::EventSVGF(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == "iterations")
            mIterations = value;
        else if (key == "feedbackTap")
            mFeedbackTap = value;
        else if (key == "phiColor")
            mPhiColor = value;
        else if (key == "phiNormal")
            mPhiNormal = value;
        else if (key == "alpha")
            mAlpha = value;
        else if (key == "momentsAlpha")
            mMomentsAlpha = value;
        else if (key == "intensityBias")
            mIntensityBias = value;
        else if (key == "useDemodulation")
            mUseDemodulation = value;
        else if (key == "useDifferenceAwareFiltering")
            mUseDifferenceAwareFiltering = value;
        else if (key == "useTemporalAccumulation")
            mUseTemporalAccumulation = value;
        else if (key == "useDenoisedDifference")
            mUseDenoisedDifference = value;
        else
            logWarning("Unknown property '{}' in EventSVGF properties.", key);
    }
    if (mIterations < 1)
        FALCOR_THROW("iterations must be at least 1.");
    if (!(mIntensityBias > 0.f))
        FALCOR_THROW("intensityBias must be positive.");
    mpReproject = ComputePass::create(mpDevice, kSVGFShader, "reproject");
    mpAtrous = ComputePass::create(mpDevice, kSVGFShader, "atrous");
    mpFinalize = ComputePass::create(mpDevice, kSVGFShader, "finalize");
}

Properties EventSVGF::getProperties() const
{
    Properties props;
    props["iterations"] = mIterations;
    props["feedbackTap"] = mFeedbackTap;
    props["phiColor"] = mPhiColor;
    props["phiNormal"] = mPhiNormal;
    props["alpha"] = mAlpha;
    props["momentsAlpha"] = mMomentsAlpha;
    props["intensityBias"] = mIntensityBias;
    props["useDemodulation"] = mUseDemodulation;
    props["useDifferenceAwareFiltering"] = mUseDifferenceAwareFiltering;
    props["useTemporalAccumulation"] = mUseTemporalAccumulation;
    props["useDenoisedDifference"] = mUseDenoisedDifference;
    return props;
}

RenderPassReflection EventSVGF::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kSVGFInputs);
    addRenderPassOutputs(reflector, kSVGFOutputs, ResourceBindFlags::UnorderedAccess);
    return reflector;
}

void EventSVGF::allocate(uint2 dim)
{
    auto create = [&](ResourceFormat format)
    {
        return mpDevice->createTexture2D(dim.x, dim.y, format, 1, 1, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    };
    for (int i = 0; i < 2; i++)
    {
        mpZN[i] = create(ResourceFormat::RGBA32Float);
        mpMoments[i] = create(ResourceFormat::RG32Float);
        mpHistory[i] = create(ResourceFormat::RG32Float);
        mpReprojected[i] = create(ResourceFormat::R32Float);
        mpPingPong[i] = create(ResourceFormat::RGBA32Float);
    }
    mpPrevFiltered = create(ResourceFormat::RGBA32Float);
    mpPrevPrevFiltered = create(ResourceFormat::RGBA32Float);
    mpPrevIllumination2 = create(ResourceFormat::R32Float);
    mpPrevAlbedoEmission = create(ResourceFormat::RGBA32Float);
    mpPrevFinalIllumination = create(ResourceFormat::R32Float);
    mpIllumination = create(ResourceFormat::RGBA32Float);
    mDim = dim;
}

void EventSVGF::clearHistory(RenderContext* pRenderContext)
{
    for (const auto& pTexture : {mpZN[1], mpMoments[1], mpHistory[1], mpReprojected[1], mpPrevFiltered,
             mpPrevPrevFiltered, mpPrevIllumination2, mpPrevAlbedoEmission, mpPrevFinalIllumination})
        pRenderContext->clearUAV(pTexture->getUAV().get(), float4(0.f));
}

void EventSVGF::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const ref<Texture> pColor1 = renderData.getTexture("color1");
    const uint2 dim = uint2(pColor1->getWidth(), pColor1->getHeight());
    if (any(dim != mDim))
    {
        allocate(dim);
        reset();
    }
    if (mClearHistory)
    {
        clearHistory(pRenderContext);
        mClearHistory = false;
    }

    auto bindCommon = [&](const ref<ComputePass>& pPass)
    {
        auto var = pPass->getRootVar();
        var["CB"]["gFrameDim"] = dim;
        var["CB"]["gFrameCount"] = mFrameCount;
        var["CB"]["gAlpha"] = mAlpha;
        var["CB"]["gMomentsAlpha"] = mMomentsAlpha;
        var["CB"]["gUseDemodulation"] = uint(mUseDemodulation);
        var["CB"]["gUseTemporalAccumulation"] = uint(mUseTemporalAccumulation);
        var["CB"]["gPhiColor"] = mPhiColor;
        var["CB"]["gPhiNormal"] = mPhiNormal;
        var["CB"]["gUseDifferenceAwareFiltering"] = uint(mUseDifferenceAwareFiltering);
        var["CB"]["gUseDenoisedDifference"] = uint(mUseDenoisedDifference);
        var["CB"]["gIntensityBias"] = mIntensityBias;
        var["gZN"] = mpZN[0];
        var["gPrevZN"] = mpZN[1];
        return var;
    };

    // 1. Temporal accumulation.
    {
        auto var = bindCommon(mpReproject);
        var["gColor1"] = pColor1;
        var["gColor2"] = renderData.getTexture("color2");
        var["gAlbedo"] = renderData.getTexture("albedo");
        var["gEmission"] = renderData.getTexture("emission");
        var["gLinearZ"] = renderData.getTexture("linearZ");
        var["gNormal"] = renderData.getTexture("normal");
        var["gMotion"] = renderData.getTexture("mvec");
        var["gPrevFiltered"] = mpPrevFiltered;
        var["gPrevPrevFiltered"] = mpPrevPrevFiltered;
        var["gPrevMoments"] = mpMoments[1];
        var["gMoments"] = mpMoments[0];
        var["gPrevHistory"] = mpHistory[1];
        var["gHistory"] = mpHistory[0];
        var["gPrevReprojected"] = mpReprojected[1];
        var["gReprojected"] = mpReprojected[0];
        var["gPrevIllumination2"] = mpPrevIllumination2;
        var["gPrevAlbedoEmission"] = mpPrevAlbedoEmission;
        var["gIllumination"] = mpIllumination;
        mpReproject->execute(pRenderContext, uint3(dim, 1));
    }

    // 2. a-trous iterations; the feedback tap becomes frame t-1's history, the previous one frame t-2's.
    auto feedback = [&](const ref<Texture>& pSource)
    {
        std::swap(mpPrevFiltered, mpPrevPrevFiltered);
        pRenderContext->copyResource(mpPrevFiltered.get(), pSource.get());
    };
    ref<Texture> pFiltered = mpIllumination;
    {
        auto var = bindCommon(mpAtrous);
        const int32_t tap = std::min(mFeedbackTap, int32_t(mIterations) - 1);
        for (uint32_t i = 0; i < mIterations; i++)
        {
            const ref<Texture>& pTarget = mpPingPong[i % 2];
            var["CB"]["gStepSize"] = int(1u << i);
            var["gAtrousInput"] = pFiltered;
            var["gAtrousOutput"] = pTarget;
            mpAtrous->execute(pRenderContext, uint3(dim, 1));
            pFiltered = pTarget;
            if (int32_t(i) == tap)
                feedback(pFiltered);
        }
        if (mFeedbackTap < 0)
            feedback(mpIllumination);
    }

    // 3. Remodulation, dI and dL.
    {
        auto var = bindCommon(mpFinalize);
        var["gAlbedo"] = renderData.getTexture("albedo");
        var["gEmission"] = renderData.getTexture("emission");
        var["gFiltered"] = pFiltered;
        var["gPrevAlbedoEmission"] = mpPrevAlbedoEmission;
        var["gPrevFinalIllumination"] = mpPrevFinalIllumination;
        var["gDeltaI"] = renderData.getTexture("deltaI");
        var["gDeltaL"] = renderData.getTexture("deltaL");
        var["gDeltaIllumination"] = renderData.getTexture("deltaIllumination");
        var["gPrimal"] = renderData.getTexture("primal");
        mpFinalize->execute(pRenderContext, uint3(dim, 1));
    }

    for (auto* pPair : {mpZN, mpMoments, mpHistory, mpReprojected})
        std::swap(pPair[0], pPair[1]);
    mFrameCount++;
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
