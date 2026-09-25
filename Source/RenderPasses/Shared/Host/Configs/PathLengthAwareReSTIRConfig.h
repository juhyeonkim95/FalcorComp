#pragma once
#include "ConfigUtils.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/Scene.h"
#include <memory>
#include <utility>

/// Path-length-aware shift mapping: the chart on which the reconnection vertex is moved.
enum class ShiftmapMethod
{
    NO = 0,
    LOCAL_TANGENT_SURFACE = 1,
    BARYCENTRIC = 2,
    RAY_TRACE_HEMISPHERE = 3,
    AREA_ADAPTIVE = 4,
    RAY_TRACE_CHART = 5,
};

static const std::unordered_map<std::string, ShiftmapMethod> ShiftmapMethodTable = {
    {"no", ShiftmapMethod::NO},
    {"local_tangent", ShiftmapMethod::LOCAL_TANGENT_SURFACE},
    {"barycentric", ShiftmapMethod::BARYCENTRIC},
    {"ray_trace", ShiftmapMethod::RAY_TRACE_HEMISPHERE},
    {"area_adaptive", ShiftmapMethod::AREA_ADAPTIVE},
    {"ray_trace_chart", ShiftmapMethod::RAY_TRACE_CHART}
};

enum class GaugeMode
{
    CONSTANT = 0,
    ORTHO_GRAD_START = 1,
    ORTHO_AVG_GRAD = 2,
};

static const std::unordered_map<std::string, GaugeMode> GaugeModeTable = {
    {"constant", GaugeMode::CONSTANT},
    {"grad", GaugeMode::ORTHO_GRAD_START},
    {"avg_grad", GaugeMode::ORTHO_AVG_GRAD}
};

/// Spatial and temporal reuse with path-length-aware shift mapping.
struct PathLengthAwareReSTIRConfig
{
    uint spatialReuseIteration = 1;
    uint spatialReuseNeighborCount = 5;
    float spatialReuseGatherRadius = 10.0f; ///< Pixels.
    bool useTemporalReuse = false;
    float temporalHistoryLength = 20.0f;    ///< History cap in frames of samples; 0 ignores it, negative is uncapped.

    ShiftmapMethod shiftmapMethod = ShiftmapMethod::NO;
    GaugeMode gaugeMode = GaugeMode::CONSTANT;
    float2 gaugeAxis = float2(1, 0);
    uint newtonMaxIteration = 5;
    float newtonRelativeTolerance = 0.01f;
    float reconnectionRoughnessThreshold = 0.25f; ///< Both vertices of a reconnection segment must be rougher.

    uint2 laserHitVBufferRes = uint2(256, 256);

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (key == "spatialReuseIteration")
            spatialReuseIteration = value;
        else if (key == "spatialReuseNeighborCount")
            spatialReuseNeighborCount = value;
        else if (key == "spatialReuseGatherRadius")
            spatialReuseGatherRadius = value;
        else if (key == "useTemporalReuse")
            useTemporalReuse = value;
        else if (key == "temporalHistoryLength")
            temporalHistoryLength = value;
        else if (key == "shiftmapMethod")
            shiftmapMethod = parseEnumProperty(ShiftmapMethodTable, std::string(value), key);
        else if (key == "gaugeMode")
            gaugeMode = parseEnumProperty(GaugeModeTable, std::string(value), key);
        else if (key == "gaugeAxis")
            gaugeAxis = value;
        else if (key == "NewtonMaxIteration")
            newtonMaxIteration = value;
        else if (key == "NewtonRelativeTolerance")
            newtonRelativeTolerance = value;
        else if (key == "specularRoughnessThreshold")
            reconnectionRoughnessThreshold = value;
        else if (key == "laserHitVBufferRes")
            laserHitVBufferRes = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["spatialReuseIteration"] = spatialReuseIteration;
        props["spatialReuseNeighborCount"] = spatialReuseNeighborCount;
        props["spatialReuseGatherRadius"] = spatialReuseGatherRadius;
        props["useTemporalReuse"] = useTemporalReuse;
        props["temporalHistoryLength"] = temporalHistoryLength;
        props["shiftmapMethod"] = enumPropertyName(ShiftmapMethodTable, shiftmapMethod);
        props["gaugeMode"] = enumPropertyName(GaugeModeTable, gaugeMode);
        props["gaugeAxis"] = gaugeAxis;
        props["NewtonMaxIteration"] = newtonMaxIteration;
        props["NewtonRelativeTolerance"] = newtonRelativeTolerance;
        props["specularRoughnessThreshold"] = reconnectionRoughnessThreshold;
        props["laserHitVBufferRes"] = laserHitVBufferRes;
    }

    /// SHIFT_MAPPING_METHOD, SHIFT_MAPPING_GAUGE_MODE and USE_TEMPORAL_REUSE.
    DefineList getDefines() const
    {
        DefineList defines;
        defines.add("SHIFT_MAPPING_METHOD", std::to_string((uint32_t)shiftmapMethod));
        defines.add("SHIFT_MAPPING_GAUGE_MODE", std::to_string((uint32_t)gaugeMode));
        defines.add("USE_TEMPORAL_REUSE", useTemporalReuse ? "1" : "0");
        return defines;
    }

    /// Sets the shift mapping constants (Shiftmap_CB) under `shiftmapVar`.
    void bindShiftMapping(const ShaderVar& shiftmapVar) const
    {
        shiftmapVar["gGaugeAxis"] = gaugeAxis;
        shiftmapVar["gGaugeMode"] = uint(gaugeMode);
        shiftmapVar["gShiftMappingMethod"] = uint(shiftmapMethod);
        shiftmapVar["gNewtonMaxIteration"] = newtonMaxIteration;
        shiftmapVar["gNewtonRelativeTolerance"] = newtonRelativeTolerance;
    }

    /// Sets the spatial reuse neighbor count, radius and reconnection threshold under `spatialVar`.
    void bindSpatialReuse(const ShaderVar& spatialVar) const
    {
        spatialVar["neighborCount"] = spatialReuseNeighborCount;
        spatialVar["gatherRadius"] = spatialReuseGatherRadius;
        spatialVar["specularRoughnessThreshold"] = reconnectionRoughnessThreshold;
    }

    /// Spatial and temporal reuse. `temporalNote` is appended to the Temporal reuse tooltip.
    bool renderReuseUI(Gui::Widgets& widget, const std::string& temporalNote = "")
    {
        bool dirty = false;
        dirty |= widget.var("Spatial iterations", spatialReuseIteration, 0u, 16u);
        widget.tooltip("Spatial reuse passes per frame. 0 disables spatial reuse.", true);

        dirty |= widget.var("Spatial neighbors", spatialReuseNeighborCount, 1u, 64u);
        widget.tooltip("Neighbor pixels resampled in each spatial pass.", true);

        dirty |= widget.var("Spatial radius (px)", spatialReuseGatherRadius, 1.f, 128.f);
        widget.tooltip("Radius, in pixels, within which spatial neighbors are chosen.", true);

        dirty |= widget.checkbox("Temporal reuse", useTemporalReuse);
        widget.tooltip("Resample the previous frame's reservoir (reprojected with motion vectors when the mvec input "
                       "is connected)." + temporalNote, true);

        if (useTemporalReuse)
        {
            dirty |= widget.var("History length (frames)", temporalHistoryLength, -1.f, 100000.f);
            widget.tooltip("Cap on the history's sample count, in frames of samples per pixel. 0 ignores the "
                           "history; a negative value leaves it uncapped.", true);
        }
        return dirty;
    }

    /// Shift method, reconnection threshold, gauge and Newton solve.
    bool renderShiftMappingUI(Gui::Widgets& widget)
    {
        bool dirty = false;
        static const Gui::DropdownList kShiftmapMethodList = {
            {(uint32_t)ShiftmapMethod::NO, "None (naive reuse)"},
            {(uint32_t)ShiftmapMethod::LOCAL_TANGENT_SURFACE, "Local tangent"},
            {(uint32_t)ShiftmapMethod::BARYCENTRIC, "Barycentric"},
            {(uint32_t)ShiftmapMethod::RAY_TRACE_HEMISPHERE, "Ray trace"},
            {(uint32_t)ShiftmapMethod::AREA_ADAPTIVE, "Area adaptive"},
            {(uint32_t)ShiftmapMethod::RAY_TRACE_CHART, "Ray trace chart"},
        };
        uint32_t method = (uint32_t)shiftmapMethod;
        if (widget.dropdown("Method", kShiftmapMethodList, method))
        {
            shiftmapMethod = (ShiftmapMethod)method;
            dirty = true;
        }
        widget.tooltip("How a reused path is fitted to the target pixel's gate. The reconnection vertex is moved so "
                       "the path length changes by the gate difference, using a Newton solve on the chosen chart.\n"
                       "None keeps the vertex fixed (naive reuse).", true);

        dirty |= widget.var("Reconnection roughness threshold", reconnectionRoughnessThreshold, 0.f, 1.f);
        widget.tooltip("A path can reconnect at a segment only if both of its vertices are rougher than this.", true);

        if (shiftmapMethod != ShiftmapMethod::NO)
        {
            static const Gui::DropdownList kGaugeModeList = {
                {(uint32_t)GaugeMode::CONSTANT, "Constant axis"},
                {(uint32_t)GaugeMode::ORTHO_GRAD_START, "Orthogonal to start gradient"},
                {(uint32_t)GaugeMode::ORTHO_AVG_GRAD, "Orthogonal to average gradient"},
            };
            uint32_t gauge = (uint32_t)gaugeMode;
            if (widget.dropdown("Gauge", kGaugeModeList, gauge))
            {
                gaugeMode = (GaugeMode)gauge;
                dirty = true;
            }
            widget.tooltip("Fixes the direction left free by the one path-length constraint in the 2D Newton solve.", true);

            if (gaugeMode == GaugeMode::CONSTANT)
            {
                dirty |= widget.var("Gauge axis", gaugeAxis, -1.f, 1.f);
                widget.tooltip("Chart-space axis of the constant gauge. (0, 0) picks a random axis per shift.", true);
            }

            dirty |= widget.var("Newton iterations", newtonMaxIteration, 1u, 64u);
            widget.tooltip("Maximum Newton iterations per shift.", true);
        }
        return dirty;
    }
};

/// Runtime part of PathLengthAwareReSTIRConfig: the reservoirs, the spatial neighbor offsets and the temporal
/// history (the previous frame's V-buffer and camera position).
class PathLengthAwareReSTIRResources
{
public:
    static constexpr uint32_t kNeighborOffsetCount = 8192;

    ref<Buffer> prevReservoirs;
    ref<Buffer> currReservoirs;
    ref<Texture> neighborOffsets;
    ref<Texture> temporalVBuffer;
    bool temporalHistoryValid = false;
    float3 previousCameraPosition = float3(0.f);

    /// Forgets what depends on the scene: the reservoir type and the history.
    void resetScene()
    {
        mpReflectTypes = nullptr;
        temporalHistoryValid = false;
    }

    /// Discards the history on scene changes it cannot follow: anything but camera motion (and light changes
    /// when `dynamicLight`), a light change otherwise, and depth of field.
    void invalidateHistory(const Scene& scene, bool lightChanged, bool dynamicLight)
    {
        auto allowedUpdates =
            IScene::UpdateFlags::CameraMoved | IScene::UpdateFlags::CameraPropertiesChanged | IScene::UpdateFlags::CameraSwitched;
        if (dynamicLight)
            allowedUpdates |= IScene::UpdateFlags::LightsMoved | IScene::UpdateFlags::LightIntensityChanged |
                              IScene::UpdateFlags::LightPropertiesChanged | IScene::UpdateFlags::SceneGraphChanged;
        if ((scene.getUpdates() & ~allowedUpdates) != IScene::UpdateFlags::None || (!dynamicLight && lightChanged) ||
            scene.getCamera()->getApertureRadius() > 0.f)
            temporalHistoryValid = false;
    }

    /// (Re)allocates `reservoirsPerPixel` reservoirs per pixel, of the type that `reflectTypesFile` reflects under
    /// `reflectDefines`; the neighbor offsets; and, with temporal reuse, the previous frame's V-buffer. A resize
    /// discards the history.
    void prepare(
        ref<Device> pDevice,
        const ref<Scene>& pScene,
        const std::string& reflectTypesFile,
        const DefineList& reflectDefines,
        uint32_t reservoirsPerPixel,
        uint2 frameDim,
        bool useTemporalReuse,
        ResourceFormat vbufferFormat
    )
    {
        if (!mpReflectTypes)
        {
            ProgramDesc desc;
            desc.addShaderModules(pScene->getShaderModules());
            desc.addTypeConformances(pScene->getTypeConformances());
            desc.addShaderLibrary(reflectTypesFile).csEntry("main");
            mpReflectTypes = ComputePass::create(pDevice, desc, reflectDefines, false);
        }
        // Set (not add) the defines to replace stale state; recreating the vars recompiles if needed.
        mpReflectTypes->getProgram()->setDefines(reflectDefines);
        mpReflectTypes->setVars(nullptr);

        if (any(mHistoryDim != frameDim))
            temporalHistoryValid = false;

        const ShaderVar reservoirVar = mpReflectTypes->getRootVar()["reservoirs"];
        const uint32_t reservoirCount = frameDim.x * frameDim.y * reservoirsPerPixel;
        for (ref<Buffer>* pReservoirs : {&prevReservoirs, &currReservoirs})
        {
            if (!*pReservoirs || (*pReservoirs)->getElementCount() != reservoirCount)
            {
                temporalHistoryValid = false;
                *pReservoirs = pDevice->createStructuredBuffer(
                    reservoirVar, reservoirCount, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
                    MemoryType::DeviceLocal, nullptr, false
                );
            }
        }

        if (!neighborOffsets)
            neighborOffsets = createNeighborOffsetTexture(pDevice, kNeighborOffsetCount);

        if (useTemporalReuse && (!temporalVBuffer || any(mHistoryDim != frameDim) || temporalVBuffer->getFormat() != vbufferFormat))
        {
            temporalVBuffer = pDevice->createTexture2D(frameDim.x, frameDim.y, vbufferFormat, 1, 1);
            mHistoryDim = frameDim;
            temporalHistoryValid = false;
        }
    }

    /// Runs `iterations` spatial reuse passes, swapping the reservoirs before each. `spatialVar` receives
    /// prevReservoirs, currReservoirs and a fresh gRandomSeed.
    void runSpatialReuse(
        RenderContext* pRenderContext,
        const ref<ComputePass>& pPass,
        const ShaderVar& spatialVar,
        uint iterations,
        uint& randomSeed,
        uint2 frameDim
    )
    {
        for (uint iteration = 0; iteration < iterations; iteration++)
        {
            std::swap(currReservoirs, prevReservoirs);
            spatialVar["gRandomSeed"] = randomSeed++;
            spatialVar["prevReservoirs"] = prevReservoirs;
            spatialVar["currReservoirs"] = currReservoirs;
            pPass->execute(pRenderContext, {frameDim.x, frameDim.y, 1});
        }
    }

    /// The final reservoirs become the next frame's history, which stays valid with temporal reuse and a pinhole
    /// camera; keeps the V-buffer and camera position it refers to.
    void endFrame(RenderContext* pRenderContext, bool useTemporalReuse, const Scene& scene, const ref<Texture>& pVBuffer)
    {
        std::swap(currReservoirs, prevReservoirs);
        temporalHistoryValid = useTemporalReuse && scene.getCamera()->getApertureRadius() == 0.f;
        if (temporalHistoryValid)
            pRenderContext->copyResource(temporalVBuffer.get(), pVBuffer.get());
        previousCameraPosition = scene.getCamera()->getPosition();
    }

private:
    /// Low-discrepancy offsets in the unit disk (R2 sequence), stored as RG8Snorm.
    static ref<Texture> createNeighborOffsetTexture(ref<Device> pDevice, uint32_t sampleCount)
    {
        std::unique_ptr<int8_t[]> offsets(new int8_t[sampleCount * 2]);
        const int R = 254;
        const float phi2 = 1.f / 1.3247179572447f;
        float u = 0.5f;
        float v = 0.5f;
        for (uint32_t index = 0; index < sampleCount * 2;)
        {
            u += phi2;
            v += phi2 * phi2;
            if (u >= 1.f)
                u -= 1.f;
            if (v >= 1.f)
                v -= 1.f;

            float rSq = (u - 0.5f) * (u - 0.5f) + (v - 0.5f) * (v - 0.5f);
            if (rSq > 0.25f)
                continue;

            offsets[index++] = int8_t((u - 0.5f) * R);
            offsets[index++] = int8_t((v - 0.5f) * R);
        }
        return pDevice->createTexture1D(sampleCount, ResourceFormat::RG8Snorm, 1, 1, offsets.get());
    }

    ref<ComputePass> mpReflectTypes;
    uint2 mHistoryDim = uint2(0);
};
