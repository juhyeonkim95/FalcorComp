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
#include "Utils/Sampling/SampleGenerator.h"
#include "../Shared/Configs/PathTracingConfig.h"
#include "../Shared/Utils/InlinePassUtils.h"

using namespace Falcor;

/** Shows where the laser is, drawn over an optional input image:
 * - the laser spot: the light the laser puts on the surface seen in each pixel, not time gated (red channel);
 * - a marker at the point the laser's central beam hits, visible even for a collimated beam.
 * The laser comes from the laser pass (LaserVBufferRT) or, with laserCollocated, from the camera.
 */
class LaserPositionViewer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(LaserPositionViewer, "LaserPositionViewer", "Draw the laser spot and the beam's hit point over an image.");

    static ref<LaserPositionViewer> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<LaserPositionViewer>(pDevice, props);
    }

    LaserPositionViewer(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

private:
    bool mShowSpot = true;
    float mSpotScale = 1.f;          ///< Multiplies the spot's radiance before it is added to the red channel.
    bool mShowMarker = true;
    float mMarkerBrightness = 10.f;  ///< Marker value (before tone mapping).
    bool mLaserCollocated = false;   ///< Place the laser at the camera, as the path tracers' laserCollocated.

    bool mOptionsChanged = false;
    uint mFrameCount = 0;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpPass;
};
