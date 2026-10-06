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
#include "../Shared/Host/LaserState.h"
#include "../Shared/Host/InlinePassUtils.h"
#include "../Shared/Host/ObjectMotion.h"

using namespace Falcor;

/** Ground-truth velocity of the direct path camera -> primary hit (pixel-center ray) -> light, per pixel (m/s), for
 * the Doppler passes. Modes:
 * - doppler: half the path velocity u of the direct path (Kim et al. 2025, Eq. 32), as DopplerHistogramPathTracerInline
 *   bins it (u / wavelength): the velocity of the hit surface point (and of the camera and light) along the path's
 *   segments. Nothing moves.
 * - path_length: -(l(dt) - l(0)) / (2 dt), the change of the direct path length along the fixed pixel ray between the
 *   scene at time 0 and at time dt, as Doppler ToF measures it. The moving objects really move (built as animated).
 * - projection: the velocity of the hit surface point along a given direction. Nothing moves.
 * Visibility of the light is ignored. Pixels without a hit are NaN. Velocities use the format of the Doppler passes.
 */
class VelocityGroundTruthInline : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(VelocityGroundTruthInline, "VelocityGroundTruthInline",
        "Ground-truth velocity of the direct path per pixel (Doppler, path-length difference or projection).");
    static ref<VelocityGroundTruthInline> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<VelocityGroundTruthInline>(pDevice, props);
    }
    VelocityGroundTruthInline(ref<Device> pDevice, const Properties& props);
    ~VelocityGroundTruthInline() override { mMover.restore(); }
    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override;
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;

    enum class Mode { Doppler = 0, PathLength = 1, Projection = 2 };
    void setVelocity(const std::string& name, float3 linear, float3 angular, float3 center);
    /// (instance index, mesh name, material name, movable) of every geometry instance of the scene.
    std::vector<std::tuple<uint32_t, std::string, std::string, bool>> getObjectNames() const;

private:
    struct Options
    {
        Mode mode = Mode::Doppler;
        float dt = 1e-3f;                        ///< path_length: time step, s.
        float3 direction = float3(0.f, 0.f, 1.f); ///< projection: direction (normalized when used).
        float3 sensorVelocity = float3(0.f);     ///< doppler: camera velocity, m/s.
        float3 lightVelocity = float3(0.f);      ///< doppler: light origin velocity, m/s.
        ObjectMotions velocities;
    };
    static void validateOptions(const Options& options);
    void parseProperties(const Properties& props);

    Options mOptions;
    bool mVelocitiesDirty = true;
    ref<Scene> mpScene;
    ref<SampleGenerator> mpSampleGenerator;
    ref<ComputePass> mpComputePass;
    ref<Buffer> mpInstanceVelocities;
    ref<Texture> mpFirstLength; ///< path_length: the path length at time 0.
    SceneMover mMover;
};
