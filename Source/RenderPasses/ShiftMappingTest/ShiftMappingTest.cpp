/** ShiftMappingTest: per-pixel bijectivity test of the path-length-aware shift mappings in the configuration of ReSTIR's
    spatial reuse (ShiftMappingTest.cs.slang). Not for release.
    Outputs (RGBA32Float):
    - shift: (forward success, |x'' - x| or -1 when the reverse fails, |J_f J_r - 1|, |x' - x|);
    - shiftValues: (J_f, J_r, |J_finite-difference / J_f - 1| or -1, condition offset);
    - shiftStatus: (forward status, forward iterations, reverse status, reverse iterations), -1 when not run.
*/
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "../Shared/Host/Configs/ShiftMappingConfig.h"
#include "../Shared/Host/InlinePassUtils.h"

using namespace Falcor;

namespace
{
const char kShaderFile[] = "RenderPasses/ShiftMappingTest/ShiftMappingTest.cs.slang";
const ChannelList kOutputChannels = {
    {"shift", "gShift", "Round trip", false, ResourceFormat::RGBA32Float},
    {"shiftValues", "gShiftValues", "Jacobians", false, ResourceFormat::RGBA32Float},
    {"shiftStatus", "gShiftStatus", "Solver status and iterations", false, ResourceFormat::RGBA32Float},
};
} // namespace

class ShiftMappingTest : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ShiftMappingTest, "ShiftMappingTest", "Tests the path-length-aware shift mappings.");

    static ref<ShiftMappingTest> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<ShiftMappingTest>(pDevice, props);
    }

    ShiftMappingTest(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
    {
        for (const auto& [key, value] : props)
        {
            if (mShiftMapping.parse(key, value))
                continue;
            if (key == "lengthChange")
                mLengthChange = value;
            else if (key == "neighborRadius")
                mNeighborRadius = value;
            else if (key == "nextIsLight")
                mNextIsLight = value;
            else if (key == "epsilon")
                mEpsilon = value;
            else if (key == "seed")
                mSeed = value;
            else
                logWarning("Unknown property '{}' in ShiftMappingTest properties.", key);
        }
        mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    }

    Properties getProperties() const override
    {
        Properties props;
        mShiftMapping.serialize(props);
        props["lengthChange"] = mLengthChange;
        props["neighborRadius"] = mNeighborRadius;
        props["nextIsLight"] = mNextIsLight;
        props["epsilon"] = mEpsilon;
        props["seed"] = mSeed;
        return props;
    }

    RenderPassReflection reflect(const CompileData& compileData) override
    {
        RenderPassReflection reflector;
        addRenderPassInputs(reflector, InlinePass::kPrimaryHitInputChannels);
        addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess);
        return reflector;
    }

    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override
    {
        mpScene = pScene;
        mpPass = nullptr;
    }

    void execute(RenderContext* pRenderContext, const RenderData& renderData) override
    {
        if (!mpScene)
            return;
        DefineList defines = mShiftMapping.getDefines();
        defines.add(getValidResourceDefines(InlinePass::kPrimaryHitInputChannels, renderData));
        if (!mpPass)
            mpPass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, defines);
        InlinePass::updateScenePassDefines(pRenderContext, mpPass, mpScene, mpSampleGenerator, defines);
        auto var = mpPass->getRootVar();
        const uint2 frameDim = renderData.getDefaultTextureDims();
        var["CB"]["gFrameDim"] = frameDim;
        var["CB"]["gSeed"] = mSeed + mFrame++;
        var["CB"]["gLengthChange"] = mLengthChange;
        var["CB"]["gNeighborRadius"] = mNeighborRadius;
        var["CB"]["gNextIsLight"] = mNextIsLight ? 1u : 0u;
        var["CB"]["gEpsilon"] = mEpsilon;
        mShiftMapping.bindShaderData(var["ShiftMappingCB"]);
        InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitInputChannels);
        InlinePass::bindChannels(var, renderData, kOutputChannels);
        mpPass->execute(pRenderContext, uint3(frameDim, 1));
    }

private:
    ShiftMappingConfig mShiftMapping;
    float mLengthChange = 0.f;   ///< Extra length change, uniform in [-this, this] (0: plain spatial reuse).
    float mNeighborRadius = 8.f; ///< Pixel radius of the source pixel around the target pixel.
    bool mNextIsLight = false;   ///< y is the camera (a collocated point light) instead of a surface.
    float mEpsilon = 1e-3f;      ///< Finite-difference step in barycentrics; 0 skips the check.
    uint mSeed = 0;
    uint mFrame = 0;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpPass;
};

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ShiftMappingTest>();
}
