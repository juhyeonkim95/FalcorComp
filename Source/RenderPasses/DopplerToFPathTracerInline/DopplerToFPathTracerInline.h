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
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/InlinePassUtils.h"
#include "../Shared/Host/ObjectMotion.h"
#include <map>
#include <random>

using namespace Falcor;

/** Inline path tracer for Doppler time-of-flight (heterodyne CW-ToF, low-pass model). The light is modulated at
 * modulationFrequency and the sensor at modulationFrequency - heterodyneFrequency; over the exposure [0, T) the camera
 * measures
 *     I = (1 / T) int_0^T int f(x, t) cos(2 pi (df t - f_g l(x, t) / c - phase)) dx dt,
 * which cancels for static paths when T is a multiple of 1 / df, and leaves a signal for paths whose length l changes
 * with time. The scene really moves: every frame draws a time t, moves the objects to their pose at t (rigid motion,
 * linear + angular velocity, applied to their scene-graph nodes) and traces the paths there. With an antithetic
 * pairing, the same frame also renders time t' (t + 1 / (2 df), or T - t) with the same random numbers (random
 * replay), and the output is the mean of the two.
 * Only objects built as animated can move (e.g. addTriangleMesh(..., isAnimated=True) in a .pyscene): static meshes
 * are pre-transformed into a merged acceleration structure.
 */
class DopplerToFPathTracerInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(DopplerToFPathTracerInline, "DopplerToFPathTracerInline",
        "Inline path tracer for Doppler time-of-flight with moving objects.");
    static ref<DopplerToFPathTracerInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<DopplerToFPathTracerInline>(pDevice, props);
    }
    DopplerToFPathTracerInline(ref<Device> pDevice, const Properties& props);
    /// Leaves the scene as it was built.
    ~DopplerToFPathTracerInline() override { mMover.restore(); }
    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

    enum class TimeSampling { Uniform = 0, Stratified = 1 };
    enum class Antithetic { None = 0, HalfPeriod = 1, Mirror = 2 };

    void setVelocity(const std::string& name, float3 linear, float3 angular, float3 center);
    void clearVelocities();
    /// Restarts the time sequence (the next frame is pair 0).
    void resetSequence() { mFrameCount = 0; }
    /// (instance index, mesh name, material name, movable) of every geometry instance of the scene.
    std::vector<std::tuple<uint32_t, std::string, std::string, bool>> getObjectNames() const;

private:
    struct Options
    {
        PathTracingConfig pathTracing;
        float modulationFrequency = 100.f;  ///< f_g, MHz.
        float heterodyneFrequency = 20.f;   ///< df = f_g - f_s, Hz.
        float exposureTime = 0.05f;         ///< T, s.
        float phase = 0.f;                  ///< Sensor phase, periods.
        TimeSampling timeSampling = TimeSampling::Stratified;
        Antithetic antithetic = Antithetic::HalfPeriod;
        bool randomReplay = true;           ///< The partner time uses the same random numbers; false: new ones.
        ObjectMotions velocities;           ///< Object name -> motion.
        uint seed = 0;                      ///< Offsets the time sequence and the path random numbers.
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);
    float sampleTime(uint pair) const;
    DefineList getShaderDefines(const RenderData& renderData) const;

    Options mOptions;
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
    std::string mUIWarning; ///< Why the last UI edit was rejected.
    bool mNodesDirty = true;
    ref<Scene> mpScene;
    LaserInput mLaserInput; ///< The laser of this frame, from the LaserLight pass.
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
    /// Moves the named objects to each sampled time and back to their base pose at the end of the frame (applied by
    /// the next scene update), so that the scene is left as it was built for the other passes and the next frame.
    SceneMover mMover;
};
