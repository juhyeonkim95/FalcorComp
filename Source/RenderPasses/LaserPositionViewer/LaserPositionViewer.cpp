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
#include "LaserPositionViewer.h"
#include "RenderGraph/RenderPassHelpers.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, LaserPositionViewer>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/LaserPositionViewer/LaserPositionViewer.cs.slang";
const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",     "gVBuffer", "Visibility buffer in packed format" },
    { kInputViewDir, "gViewW",   "World-space view direction (xyz float format)", true /* optional */ },
    { "input",       "gInput",   "Image to draw on, e.g. a tracer's color output (black if not connected)", true /* optional */ },
    // clang-format on
};

const ChannelList kOutputChannels = {
    { "output", "gOutput", "The input with the laser spot and cone", false, ResourceFormat::RGBA32Float },
};

const char kShowSpot[] = "showSpot";
const char kSpotScale[] = "spotScale";
const char kSpotColor[] = "spotColor";
const char kShowCone[] = "showCone";
const char kConeColor[] = "coneColor";
const char kConeDensity[] = "coneDensity";
const char kBeamRadius[] = "beamRadius";
} // namespace

LaserPositionViewer::LaserPositionViewer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kShowSpot)
            mShowSpot = value;
        else if (key == kSpotScale)
            mSpotScale = value;
        else if (key == kSpotColor)
            mSpotColor = value;
        else if (key == kShowCone)
            mShowCone = value;
        else if (key == kConeColor)
            mConeColor = value;
        else if (key == kConeDensity)
            mConeDensity = value;
        else if (key == kBeamRadius)
            mBeamRadius = value;
        else
            logWarning("Unknown property '{}' in LaserPositionViewer properties.", key);
    }
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
}

Properties LaserPositionViewer::getProperties() const
{
    Properties props;
    props[kShowSpot] = mShowSpot;
    props[kSpotScale] = mSpotScale;
    props[kSpotColor] = mSpotColor;
    props[kShowCone] = mShowCone;
    props[kConeColor] = mConeColor;
    props[kConeDensity] = mConeDensity;
    props[kBeamRadius] = mBeamRadius;
    return props;
}

RenderPassReflection LaserPositionViewer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void LaserPositionViewer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged)
    {
        InlinePass::flagOptionsChanged(renderData);
        mOptionsChanged = false;
    }
    if (!mpScene)
    {
        InlinePass::clearChannels(pRenderContext, renderData, kOutputChannels);
        return;
    }

    DefineList defines;
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    if (!mpPass)
        mpPass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, defines);
    mpPass->getProgram()->addDefines(defines);

    const uint2 frameDim = renderData.getDefaultTextureDims();
    auto var = mpPass->getRootVar();
    var["CB"]["gFrameDim"] = frameDim;
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gSpotScale"] = mSpotScale;
    var["CB"]["gSpotColor"] = mSpotColor;
    var["CB"]["gShowCone"] = uint(mShowCone);
    var["CB"]["gConeColor"] = mConeColor;
    var["CB"]["gConeDensity"] = mConeDensity;
    var["CB"]["gBeamRadius"] = mBeamRadius;
    var["CB"]["gShowSpot"] = uint(mShowSpot);
    LaserState::resolve(renderData).bindShaderData(var["CB"]);
    InlinePass::bindChannels(var, renderData, kInputChannels);
    InlinePass::bindChannels(var, renderData, kOutputChannels);
    mpPass->execute(pRenderContext, uint3(frameDim, 1));
    mFrameCount++;
}

void LaserPositionViewer::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    dirty |= widget.checkbox("Show laser spot", mShowSpot);
    widget.tooltip("Add the light the laser puts on the surface seen in each pixel, not time gated. A collimated "
                   "beam (laserAngle 0) lights no pixel.", true);
    if (mShowSpot)
    {
        dirty |= widget.var("Spot scale", mSpotScale, 0.f, 1e6f);
        widget.tooltip("Multiplies the spot's radiance (average of RGB).", true);
        dirty |= widget.rgbColor("Spot color", mSpotColor);
    }

    dirty |= widget.checkbox("Show laser cone", mShowCone);
    widget.tooltip("Draw the laser's cone like light in fog: it starts at the laser with radius Beam radius, widens "
                   "at the cone angle (laserAngle) and ends where the central beam hits the scene.", true);
    if (mShowCone)
    {
        dirty |= widget.rgbColor("Cone color", mConeColor);
        dirty |= widget.var("Cone density", mConeDensity, 0.f, 1e6f);
        widget.tooltip("Opacity per unit length inside the cone: opacity = 1 - exp(-density * length).", true);
        dirty |= widget.var("Beam radius", mBeamRadius, 0.f, 10.f, 0.001f);
        widget.tooltip("Cone radius at the laser, in scene units; keeps a collimated beam visible.", true);
    }

    if (dirty)
        mOptionsChanged = true;
}

void LaserPositionViewer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpPass = nullptr;
    mFrameCount = 0;
    mpScene = pScene;
}
