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
#include "TransientHistogramAccumulatePass.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "../Shared/Configs/TransientHistogramConfig.h"

static void regTransientHistogramAccumulatePass(pybind11::module& m)
{
    pybind11::class_<TransientHistogramAccumulatePass, RenderPass, ref<TransientHistogramAccumulatePass>> pass(m, "TransientHistogramAccumulatePass");
    pass.def("reset", &TransientHistogramAccumulatePass::reset);
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, TransientHistogramAccumulatePass>();
    ScriptBindings::registerBinding(regTransientHistogramAccumulatePass);
}

namespace
{
const char kShaderFile[] = "RenderPasses/TransientHistogramAccumulatePass/TransientHistogramAccumulatePass.cs.slang";

const char kInput[] = "input";
const char kOutput[] = "output";

const char kEnabled[] = "enabled";
const char kAutoReset[] = "autoReset";
const char kPrecisionMode[] = "precisionMode";
const char kMaxFrameCount[] = "maxFrameCount";
} // namespace

TransientHistogramAccumulatePass::TransientHistogramAccumulatePass(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kEnabled)
            mEnabled = value;
        else if (key == kAutoReset)
            mAutoReset = value;
        else if (key == kPrecisionMode)
        {
            const std::string mode = value;
            if (mode == "Single")
                mPrecision = Precision::Single;
            else if (mode == "SingleCompensated")
                mPrecision = Precision::SingleCompensated;
            else
                FALCOR_THROW("precisionMode must be Single or SingleCompensated.");
        }
        else if (key == kMaxFrameCount)
            mMaxFrameCount = value;
        else
            logWarning("Unknown property '{}' in TransientHistogramAccumulatePass properties.", key);
    }
}

Properties TransientHistogramAccumulatePass::getProperties() const
{
    Properties props;
    props[kEnabled] = mEnabled;
    props[kAutoReset] = mAutoReset;
    props[kPrecisionMode] = mPrecision == Precision::Single ? "Single" : "SingleCompensated";
    props[kMaxFrameCount] = mMaxFrameCount;
    return props;
}

std::pair<uint3, ResourceFormat> TransientHistogramAccumulatePass::inputShape(const CompileData& compileData)
{
    uint3 dims = {compileData.defaultTexDims.x, compileData.defaultTexDims.y, 1};
    ResourceFormat format = ResourceFormat::RGBA32Float;
    if (const auto* pField = compileData.connectedResources.getField(kInput))
    {
        if (pField->getWidth() > 0)
            dims.x = pField->getWidth();
        if (pField->getHeight() > 0)
            dims.y = pField->getHeight();
        if (pField->getDepth() > 0)
            dims.z = pField->getDepth();
        if (pField->getFormat() != ResourceFormat::Unknown)
            format = pField->getFormat();
    }
    return {dims, format};
}

RenderPassReflection TransientHistogramAccumulatePass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    reflector.addInput(kInput, "Transient histogram of one frame (width x height x bins)").texture3D(0, 0, 0);

    // The output takes the input's shape and format; compile() asks again until the graph knows them.
    mDeclaredShape = inputShape(compileData);
    const auto& [dims, format] = mDeclaredShape;
    reflector.addOutput(kOutput, "Mean histogram over the averaged frames")
        .texture3D(dims.x, dims.y, dims.z)
        .format(format)
        .bindFlags(ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    return reflector;
}

void TransientHistogramAccumulatePass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    // reflect() may run before the input is connected. Failing here makes the graph compiler reflect again,
    // now with the input's shape (see RenderGraphCompiler::compilePasses()).
    const auto [dims, format] = inputShape(compileData);
    if (any(dims != mDeclaredShape.first) || format != mDeclaredShape.second)
        FALCOR_THROW("TransientHistogramAccumulatePass: the output shape is not known yet.");
}

bool TransientHistogramAccumulatePass::needsAutoReset(const RenderData& renderData) const
{
    // Same rule as AccumulatePass: any refresh flag, or a scene change other than camera jitter/history.
    auto& dict = renderData.getDictionary();
    if (dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None) != RenderPassRefreshFlags::None)
        return true;
    if (!mpScene)
        return false;
    const auto sceneUpdates = mpScene->getUpdates();
    if ((sceneUpdates & ~IScene::UpdateFlags::CameraPropertiesChanged) != IScene::UpdateFlags::None)
        return true;
    if (is_set(sceneUpdates, IScene::UpdateFlags::CameraPropertiesChanged))
    {
        const auto excluded = Camera::Changes::Jitter | Camera::Changes::History;
        if ((mpScene->getCamera()->getChanges() & ~excluded) != Camera::Changes::None)
            return true;
    }
    return false;
}

void TransientHistogramAccumulatePass::prepareState(const ref<Texture>& pInput)
{
    // The running mean (and the Kahan compensation) has the input's shape; reallocating restarts the average.
    auto matches = [&](const ref<Texture>& pTexture)
    {
        return pTexture && pTexture->getWidth() == pInput->getWidth() && pTexture->getHeight() == pInput->getHeight() &&
               pTexture->getDepth() == pInput->getDepth() && pTexture->getFormat() == pInput->getFormat();
    };
    auto create = [&]()
    {
        return mpDevice->createTexture3D(
            pInput->getWidth(), pInput->getHeight(), pInput->getDepth(), pInput->getFormat(), 1, nullptr,
            ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource
        );
    };
    if (!matches(mpMean))
    {
        mpMean = create();
        mpCompensation = nullptr;
        mFrameCount = 0;
    }
    if (mPrecision == Precision::SingleCompensated && !matches(mpCompensation))
    {
        mpCompensation = create();
        mFrameCount = 0;
    }
    if (mPrecision == Precision::Single)
        mpCompensation = nullptr;
}

void TransientHistogramAccumulatePass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const ref<Texture> pInput = renderData.getTexture(kInput);
    const ref<Texture> pOutput = renderData.getTexture(kOutput);
    auto& dict = renderData.getDictionary();

    if (!mEnabled)
    {
        pRenderContext->copyResource(pOutput.get(), pInput.get());
        mFrameCount = 0;
        dict[TransientHistogramConfig::kFrameCountKey] = 1u;
        return;
    }

    if (mAutoReset && needsAutoReset(renderData))
        reset();
    prepareState(pInput);

    // Past the frame limit, keep showing the last average.
    if (mMaxFrameCount > 0 && mFrameCount >= mMaxFrameCount)
    {
        pRenderContext->copyResource(pOutput.get(), mpMean.get());
        dict[TransientHistogramConfig::kFrameCountKey] = mFrameCount;
        return;
    }
    mFrameCount++;

    DefineList defines;
    defines.add("SINGLE_CHANNEL", getFormatChannelCount(pInput->getFormat()) == 1 ? "1" : "0");
    defines.add("COMPENSATED", mPrecision == Precision::SingleCompensated ? "1" : "0");
    if (!mpPass)
        mpPass = ComputePass::create(mpDevice, kShaderFile, "main", defines);
    mpPass->getProgram()->addDefines(defines);

    const uint3 dims = {pInput->getWidth(), pInput->getHeight(), pInput->getDepth()};
    auto var = mpPass->getRootVar();
    var["CB"]["gDim"] = dims;
    var["CB"]["gFrameCount"] = mFrameCount;
    var["gInput"] = pInput;
    var["gMean"] = mpMean;
    if (mpCompensation)
        var["gCompensation"] = mpCompensation;
    var["gOutput"] = pOutput;
    mpPass->execute(pRenderContext, dims);

    dict[TransientHistogramConfig::kFrameCountKey] = mFrameCount;
}

void TransientHistogramAccumulatePass::renderUI(Gui::Widgets& widget)
{
    if (widget.checkbox("Enabled", mEnabled))
        reset();
    widget.tooltip("Average the histogram over frames. Off: the output is this frame's histogram.", true);

    widget.checkbox("Auto reset", mAutoReset);
    widget.tooltip("Restart the average when the camera moves, the scene changes or an upstream pass changes its "
                   "options.", true);

    static const Gui::DropdownList kPrecisionList = {
        {(uint32_t)Precision::Single, "Single"},
        {(uint32_t)Precision::SingleCompensated, "Single (compensated)"},
    };
    uint32_t precision = (uint32_t)mPrecision;
    if (widget.dropdown("Precision", kPrecisionList, precision))
    {
        mPrecision = (Precision)precision;
        reset();
    }
    widget.tooltip("Single: running mean in float. Compensated: adds Kahan summation for long runs, at the cost of "
                   "one more histogram-sized buffer.", true);

    widget.var("Max frames", mMaxFrameCount, 0u, 1u << 30);
    widget.tooltip("Stop averaging after this many frames and keep the result. 0 = no limit.", true);

    if (widget.button("Reset"))
        reset();
    widget.text(fmt::format("Averaged frames: {}", mFrameCount));
}

void TransientHistogramAccumulatePass::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;
    reset();
}
