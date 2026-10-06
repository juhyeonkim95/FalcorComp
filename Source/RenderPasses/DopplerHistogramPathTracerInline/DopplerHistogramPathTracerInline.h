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
#include "RenderGraph/RenderPassHelpers.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "../Shared/Host/Configs/PathTracingConfig.h"
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/InlinePassUtils.h"
#include "../Shared/Host/ObjectMotion.h"
#include <map>

using namespace Falcor;

/** Inline path tracer for the Doppler spectrum of optical heterodyne detection with a single-frequency laser (Kim et
 * al. 2025, "A Monte Carlo Rendering Framework for Simulating Optical Heterodyne Detection", Eq. 26 with B = 0).
 * Each path adds its contribution to the bin of its Doppler frequency shift f0 u(x) / c = u(x) / wavelength, where
 * u(x) is the path velocity (Eq. 32): the sum over its segments of the relative velocity of their endpoints along the
 * segment. Objects are not moved: every scene object is given an instantaneous velocity (a rigid motion, linear plus
 * angular), which only decides the bin. The output is an H x W x B spectrum, per unit frequency (MHz).
 */
class DopplerHistogramPathTracerInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(DopplerHistogramPathTracerInline, "DopplerHistogramPathTracerInline",
        "Inline path tracer for Doppler spectra of optical heterodyne detection.");
    static ref<DopplerHistogramPathTracerInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<DopplerHistogramPathTracerInline>(pDevice, props);
    }
    DopplerHistogramPathTracerInline(ref<Device> pDevice, const Properties& props);
    Properties getProperties() const override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

    /// With accumulate, restarts the sum.
    void resetSpectrum() { mNeedToClearSpectrum = true; }
    /// Sets the velocity of the scene objects whose mesh or material is named `name` (or of instance "#<index>").
    void setVelocity(const std::string& name, float3 linear, float3 angular, float3 center);
    void clearVelocities();
    /// (instance index, mesh name, material name) of every geometry instance of the scene.
    std::vector<std::tuple<uint32_t, std::string, std::string>> getObjectNames() const;

private:
    /// User settings, composed of shared configs (Shared/Host/Configs) plus this pass's own.
    struct Options
    {
        PathTracingConfig pathTracing;
        float wavelength = 1550.f;      ///< Laser wavelength, nm.
        /// Linear chirp (FMCW): the laser frequency sweeps by chirpBandwidth over chirpDuration, up and then down
        /// (a triangular chirp). 0: a single-frequency laser.
        float chirpBandwidth = 0.f;     ///< GHz.
        float chirpDuration = 10.f;     ///< Microseconds.
        float frequencyMin = -50.f;     ///< Range of (beat) frequencies, MHz.
        float frequencyMax = 50.f;
        uint frequencyBin = 256;        ///< Number of bins over [frequencyMin, frequencyMax).
        float3 sensorVelocity = float3(0.f); ///< Velocity of the camera, m/s.
        float3 lightVelocity = float3(0.f);  ///< Velocity of the laser (or point light) origin, m/s.
        ObjectMotions velocities;            ///< Object name -> motion.
        bool accumulate = false; ///< Sum frames in the spectrum instead of writing one frame per spectrum.
        RenderPassHelpers::IOSize outputSize = RenderPassHelpers::IOSize::Default;
        uint2 fixedOutputSize = {512, 512}; ///< Output size when outputSize is Fixed.

        float binWidth() const { return (frequencyMax - frequencyMin) / float(frequencyBin); }
        bool chirped() const { return chirpBandwidth > 0.f; }
        /// Range term of the beat frequency per unit optical path length, B / (T c): MHz per meter.
        float rangeFrequencyPerLength() const { return chirpBandwidth * 1000.f / (chirpDuration * 299.792458f); }
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);
    const ChannelList& spectrumChannels() const;
    bool needsReset(const RenderData& renderData) const;
    void bindShaderData(const ShaderVar& var, const RenderData& renderData);
    DefineList getShaderDefines(const RenderData& renderData) const;

    Options mOptions;
    uint mFrameCount = 0;
    uint mSummedFrames = 0;             ///< Frames in the spectrum (accumulate).
    bool mNeedToClearSpectrum = true;
    bool mOptionsChanged = false;
    bool mVelocitiesDirty = true;
    std::string mUIWarning; ///< Why the last UI edit was rejected.
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
    ref<Buffer> mpInstanceVelocities; ///< Per geometry instance: linear, angular, center (float4 each).
};
