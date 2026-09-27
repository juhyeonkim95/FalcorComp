#pragma once
#include "ConfigUtils.h"
#include "ShiftMappingConfig.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/Scene.h"
#include <memory>
#include <utility>

/// Spatial and temporal reuse with path-length-aware shift mapping.
struct PathLengthAwareReSTIRConfig
{
    uint spatialReuseIteration = 1;
    uint spatialReuseNeighborCount = 5;
    float spatialReuseGatherRadius = 10.0f; ///< Pixels.
    bool useTemporalReuse = false;
    float temporalHistoryLength = 20.0f;    ///< History cap in frames of samples; 0 ignores it, negative is uncapped.

    ShiftMappingConfig shiftMapping;
    float reconnectionRoughnessThreshold = 0.25f; ///< Both vertices of a reconnection segment must be rougher.

    bool parse(const std::string& key, const Properties::ConstValue& value)
    {
        if (shiftMapping.parse(key, value))
            return true;
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
        else if (key == "specularRoughnessThreshold")
            reconnectionRoughnessThreshold = value;
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
        shiftMapping.serialize(props);
        props["specularRoughnessThreshold"] = reconnectionRoughnessThreshold;
    }

    /// SHIFT_MAPPING_METHOD, SHIFT_MAPPING_GAUGE_MODE and USE_TEMPORAL_REUSE.
    DefineList getDefines() const
    {
        DefineList defines = shiftMapping.getDefines();
        defines.add("USE_TEMPORAL_REUSE", useTemporalReuse ? "1" : "0");
        return defines;
    }

    /// Sets the shift mapping constants (Shiftmap_CB) under `shiftmapVar`.
    void bindShiftMapping(const ShaderVar& shiftmapVar) const
    {
        shiftMapping.bindShaderData(shiftmapVar);
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
        return shiftMapping.renderUI(widget,
            "How a reused path is fitted to the target pixel's gate. The reconnection vertex is moved so the path "
            "length changes by the gate difference, using a Newton solve on the chosen chart.\n"
            "None keeps the vertex fixed (naive reuse).",
            [this](Gui::Widgets& group)
            {
                bool dirty = group.var("Reconnection roughness threshold", reconnectionRoughnessThreshold, 0.f, 1.f);
                group.tooltip("A path can reconnect at a segment only if both of its vertices are rougher than this.", true);
                return dirty;
            });
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
        // The reservoir layout depends on the defines (e.g. a scalar target with single channel).
        const size_t reservoirStride =
            reservoirVar.getType()->unwrapArray()->asResourceType()->getStructType()->getSlangTypeLayout()->getStride();
        for (ref<Buffer>* pReservoirs : {&prevReservoirs, &currReservoirs})
        {
            if (!*pReservoirs || (*pReservoirs)->getElementCount() != reservoirCount ||
                (*pReservoirs)->getStructSize() != reservoirStride)
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
