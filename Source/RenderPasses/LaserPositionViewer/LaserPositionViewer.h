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
#include "../Shared/Lights/LaserState.h"
#include "../Shared/Utils/InlinePassUtils.h"

using namespace Falcor;

/** Shows where the laser is, drawn over an optional input image:
 * - the laser spot: the light the laser puts on the surface seen in each pixel (not time gated), tinted with
 *   spotColor; a collimated beam lights no pixel;
 * - the laser's cone, drawn like light in fog: it starts at the laser with radius beamRadius (so a collimated beam
 *   shows as a thin cylinder), widens at the cone angle and ends where the central beam hits the scene.
 * The laser is the one the laser pass (LaserVBufferRT) publishes this frame.
 */
class LaserPositionViewer : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(LaserPositionViewer, "LaserPositionViewer", "Draw the laser spot and cone over an image.");

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
    float mSpotScale = 20.f;              ///< Multiplies the spot's radiance (average of RGB).
    float3 mSpotColor = float3(1, 0, 0);  ///< Tint of the spot.
    bool mShowCone = true;
    float3 mConeColor = float3(1, 0, 0);
    float mConeDensity = 20.f;            ///< Opacity per unit length inside the cone: 1 - exp(-density * length).
    float mBeamRadius = 0.01f;            ///< Cone radius at the laser, in scene units.

    bool mOptionsChanged = false;
    uint mFrameCount = 0;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpPass;
};
