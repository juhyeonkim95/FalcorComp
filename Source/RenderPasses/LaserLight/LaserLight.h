#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "../Shared/Host/LaserState.h"

using namespace Falcor;

/** The light of the time-of-flight passes: a laser, whose light is the spot its beam hits, or a point light,
 * placed in the scene or at the camera. The pass has no inputs or outputs and does no GPU work: every frame it
 * publishes the light in the render data dictionary (LaserState), where the ToF passes read it. Connect it to them
 * with an execution edge, graph.add_edge("Laser", "Tracer"), so that it runs first.
 */
class LaserLight : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(LaserLight, "LaserLight", "Laser or point light of the time-of-flight render passes.");

    static ref<LaserLight> create(ref<Device> pDevice, const Properties& props) { return make_ref<LaserLight>(pDevice, props); }

    LaserLight(ref<Device> pDevice, const Properties& props);

    Properties getProperties() const override;
    void setProperties(const Properties& props) override;
    RenderPassReflection reflect(const CompileData& compileData) override { return {}; }
    void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    void renderUI(Gui::Widgets& widget) override;
    void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override { mpScene = pScene; }

    // Scripting functions
    /// Moves the laser: `position` becomes laserPosition, from which laserVelocity moves it again. Downstream
    /// accumulation restarts, as for any change of the light.
    void updateLaserInfo(const float3& position, const float3& direction);

private:
    void parseProperties(const Properties& props);

    ref<Scene> mpScene;
    /// The properties: the origin is laserPosition, where the motion starts. Position and direction are replaced by
    /// the camera's when collocated.
    LaserState mLaser;
    LaserState mPublished;          ///< The laser published last frame, to restart accumulation when it changes.
    float3 mVelocity = float3(0.f); ///< laserVelocity, added to mPosition after every frame.
    /// This frame's position: laserPosition moved by laserVelocity once per frame since the properties, the UI's
    /// position or update_laser_info last set it. Saved properties keep laserPosition, so a saved graph replays the
    /// motion from its start.
    float3 mPosition = float3(0.f);
    bool mOptionsChanged = false;
};
