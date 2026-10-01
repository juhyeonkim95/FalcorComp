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
#include "../Shared/Host/Configs/PathTracingConfig.h"
#include "../Shared/Host/Configs/TimeGateConfig.h"
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/InlinePassUtils.h"
#include "../Shared/Host/ObjectMotion.h"

using namespace Falcor;

/** Inline path tracer for a Doppler-gated image of optical heterodyne detection with a single-frequency laser: the
 * light whose Doppler frequency shift falls in a gate, as TimeGatedPathTracerInline is to the transient histogram and
 * this pass to DopplerHistogramPathTracerInline (Kim et al. 2025, Eq. 26 with B = 0). Each path is weighted by a gate
 * kernel (the time-gate kernels: box, tent, Gaussian, ...) at its shift u(x) / wavelength, and the image is divided
 * by the gate width, in radiance per MHz. Objects are not moved; their instantaneous velocities decide the shift. The
 * gate is fixed (frequencyCenter) or scans [frequencyMin, frequencyMax) one step per frame (shiftGate).
 */
class DopplerGatedPathTracerInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(DopplerGatedPathTracerInline, "DopplerGatedPathTracerInline",
        "Inline path tracer for Doppler-gated images of optical heterodyne detection.");
    static ref<DopplerGatedPathTracerInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<DopplerGatedPathTracerInline>(pDevice, props);
    }
    DopplerGatedPathTracerInline(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

    /// Sets the velocity of the scene objects whose mesh or material is named `name` (or of instance "#<index>").
    void setVelocity(const std::string& name, float3 linear, float3 angular, float3 center);
    void clearVelocities();
    /// (instance index, mesh name, material name, movable) of every geometry instance of the scene.
    std::vector<std::tuple<uint32_t, std::string, std::string, bool>> getObjectNames() const;
    /// Moves the gate to the next scan position.
    void incrementFrequencyGateFrame();
    /// Sets the scan range and the number of positions.
    void setFrequencyGateInfo(float frequencyMin, float frequencyMax, uint frequencyBin);

private:
    /// User settings, composed of shared configs (Shared/Host/Configs) plus this pass's own.
    struct Options
    {
        PathTracingConfig pathTracing;
        /// The gate, with the time gate's kernels over the Doppler shift: centers and width in MHz.
        TimeGateConfig gate = defaultGate();
        float wavelength = 1550.f;           ///< Laser wavelength, nm.
        float3 sensorVelocity = float3(0.f); ///< Velocity of the camera, m/s.
        float3 lightVelocity = float3(0.f);  ///< Velocity of the laser (or point light) origin, m/s.
        ObjectMotions velocities;            ///< Object name -> motion.

        static TimeGateConfig defaultGate()
        {
            TimeGateConfig gate;
            gate.timeMin = gate.timeMax = 0.f; // A fixed gate at 0 MHz.
            gate.timeGateWindow = 1.f;
            return gate;
        }
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;

    Options mOptions;
    TimeGateState mGate;
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
    bool mVelocitiesDirty = true;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
    ref<Buffer> mpInstanceVelocities;
};
