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
    { "input",       "gInput",   "Image to draw on, e.g. a tracer's color output; without it the output is the overlay", true /* optional */ },
    // clang-format on
};

const ChannelList kOutputChannels = {
    { "output", "gOutput", "The input with the laser spot and cone, or the overlay (premultiplied alpha)", false, ResourceFormat::RGBA32Float },
};

const char kShowSpot[] = "showSpot";
const char kSpotScale[] = "spotScale";
const char kSpotColor[] = "spotColor";
const char kShowCone[] = "showCone";
const char kConeColor[] = "coneColor";
const char kConeDensity[] = "coneDensity";
const char kBeamRadius[] = "beamRadius";
const char kOutputSize[] = "outputSize";
const char kFixedOutputSize[] = "fixedOutputSize";
} // namespace

LaserPositionViewer::LaserPositionViewer(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    validateOptions(mOptions);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
}

void LaserPositionViewer::validateOptions(const Options& options)
{
    if (!(options.spotScale >= 0.f) || !std::isfinite(options.spotScale) || !(options.coneDensity >= 0.f) ||
        !std::isfinite(options.coneDensity) || !(options.beamRadius >= 0.f) || !std::isfinite(options.beamRadius))
        FALCOR_THROW("spotScale, coneDensity and beamRadius must be finite and non-negative.");
}

void LaserPositionViewer::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kShowSpot)
            mOptions.showSpot = value;
        else if (key == kSpotScale)
            mOptions.spotScale = value;
        else if (key == kSpotColor)
            mOptions.spotColor = value;
        else if (key == kShowCone)
            mOptions.showCone = value;
        else if (key == kConeColor)
            mOptions.coneColor = value;
        else if (key == kConeDensity)
            mOptions.coneDensity = value;
        else if (key == kBeamRadius)
            mOptions.beamRadius = value;
        else if (key == kOutputSize)
            mOptions.outputSize = value;
        else if (key == kFixedOutputSize)
            mOptions.fixedOutputSize = value;
        else
            logWarning("Unknown property '{}' in LaserPositionViewer properties.", key);
    }
}

void LaserPositionViewer::setProperties(const Properties& props)
{
    const Options previous = mOptions;
    // Invalid properties throw and leave the options unchanged.
    InlinePass::applyProperties(mOptions, [&] { parseProperties(props); }, validateOptions);
    if (mOptions.outputSize != previous.outputSize || any(mOptions.fixedOutputSize != previous.fixedOutputSize))
        requestRecompile();
}

Properties LaserPositionViewer::getProperties() const
{
    Properties props;
    props[kShowSpot] = mOptions.showSpot;
    props[kSpotScale] = mOptions.spotScale;
    props[kSpotColor] = mOptions.spotColor;
    props[kShowCone] = mOptions.showCone;
    props[kConeColor] = mOptions.coneColor;
    props[kConeDensity] = mOptions.coneDensity;
    props[kBeamRadius] = mOptions.beamRadius;
    props[kOutputSize] = mOptions.outputSize;
    if (mOptions.outputSize == RenderPassHelpers::IOSize::Fixed)
        props[kFixedOutputSize] = mOptions.fixedOutputSize;
    return props;
}

RenderPassReflection LaserPositionViewer::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    const uint2 sz = RenderPassHelpers::calculateIOSize(mOptions.outputSize, mOptions.fixedOutputSize, compileData.defaultTexDims);
    addRenderPassOutputs(reflector, kOutputChannels, ResourceBindFlags::UnorderedAccess, sz);
    return reflector;
}

void LaserPositionViewer::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
    {
        InlinePass::clearChannels(pRenderContext, renderData, kOutputChannels);
        return;
    }

    DefineList defines;
    defines.add(getValidResourceDefines(kInputChannels, renderData));
    if (!mpPass)
        mpPass = InlinePass::createScenePass(mpDevice, pRenderContext, mpScene, mpSampleGenerator, kShaderFile, defines);
    InlinePass::updateScenePassDefines(pRenderContext, mpPass, mpScene, mpSampleGenerator, defines);

    const ref<Texture> pOutput = renderData.getTexture("output");
    const uint2 frameDim = {pOutput->getWidth(), pOutput->getHeight()};
    auto var = mpPass->getRootVar();
    var["CB"]["gFrameDim"] = frameDim;
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gSpotScale"] = mOptions.spotScale;
    var["CB"]["gSpotColor"] = mOptions.spotColor;
    const LaserState laser = LaserState::resolve(renderData);
    // A collocated laser starts at the camera, so its cone would cover the whole image.
    var["CB"]["gShowCone"] = uint(mOptions.showCone && !laser.collocated);
    var["CB"]["gConeColor"] = mOptions.coneColor;
    var["CB"]["gConeDensity"] = mOptions.coneDensity;
    var["CB"]["gBeamRadius"] = mOptions.beamRadius;
    var["CB"]["gShowSpot"] = uint(mOptions.showSpot);
    laser.bindShaderData(var["Laser"]);
    InlinePass::bindChannels(var, renderData, kInputChannels);
    InlinePass::bindChannels(var, renderData, kOutputChannels);
    mpPass->execute(pRenderContext, uint3(frameDim, 1));
    mFrameCount++;
}

void LaserPositionViewer::renderUI(Gui::Widgets& widget)
{
    // The output is redrawn every frame, so changes need no downstream reset.
    widget.checkbox("Show laser spot", mOptions.showSpot);
    widget.tooltip("Add the light the laser puts on the surface seen in each pixel, not time gated. A collimated "
                   "beam (laserAngle 0) lights no pixel.", true);
    if (mOptions.showSpot)
    {
        widget.var("Spot scale", mOptions.spotScale, 0.f, 1e6f);
        widget.tooltip("Multiplies the spot's radiance (average of RGB).", true);
        widget.rgbColor("Spot color", mOptions.spotColor);
    }

    widget.checkbox("Show laser cone", mOptions.showCone);
    widget.tooltip("Draw the laser's cone like light in fog: it starts at the laser with radius Beam radius, widens "
                   "at the cone angle (laserAngle) and ends where the central beam hits the scene. Not drawn for a "
                   "laser collocated with the camera.", true);
    if (mOptions.showCone)
    {
        widget.rgbColor("Cone color", mOptions.coneColor);
        widget.var("Cone density", mOptions.coneDensity, 0.f, 1e6f);
        widget.tooltip("Opacity per unit length inside the cone: opacity = 1 - exp(-density * length).", true);
        widget.var("Beam radius", mOptions.beamRadius, 0.f, 10.f, 0.001f);
        widget.tooltip("Cone radius at the laser, in scene units; keeps a collimated beam visible.", true);
    }

}

void LaserPositionViewer::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpPass = nullptr;
    mFrameCount = 0;
    mpScene = pScene;
}
