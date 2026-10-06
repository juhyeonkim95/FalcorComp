#pragma once
#include "ConfigUtils.h"
#include "ShiftMappingConfig.h"
#include "PathTracingConfig.h"
#include "../InlinePassUtils.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/Scene.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

/// Spatial and temporal reuse with path-length-aware shift mapping.
struct PathLengthAwareReSTIRConfig
{
    uint spatialReuseIteration = 1;
    uint spatialReuseNeighborCount = 5;
    float spatialReuseGatherRadius = 10.0f; ///< Pixels.
    /// Spatial reuse as two passes per iteration (one candidate's shifts per thread, then resampling); false runs the
    /// single-pass kernel. Same results either way; the shift `no` always uses the single pass.
    bool spatialReuseTwoPass = true;
    bool useTemporalReuse = false;
    float temporalHistoryLength = 20.0f;    ///< History cap in frames of samples; 0 ignores the history.

    ShiftMappingConfig shiftMapping;
    float reconnectionRoughnessThreshold = 0.25f; ///< Both vertices of a reconnection segment must be rougher.
    float reconnectionMinDistance = 0.f;          ///< A reconnection segment must be longer (scene units).

    void validate() const
    {
        shiftMapping.validate();
        if (spatialReuseIteration > 16)
            FALCOR_THROW("spatialReuseIteration must be in [0, 16].");
        if (spatialReuseNeighborCount < 1 || spatialReuseNeighborCount > 64)
            FALCOR_THROW("spatialReuseNeighborCount must be in [1, 64].");
        if (!std::isfinite(spatialReuseGatherRadius) || spatialReuseGatherRadius <= 0.f)
            FALCOR_THROW("spatialReuseGatherRadius must be finite and greater than zero.");
        // An uncapped history's sample count grows by the neighbor count each frame until it overflows.
        if (!std::isfinite(temporalHistoryLength) || temporalHistoryLength < 0.f)
            FALCOR_THROW("temporalHistoryLength must be finite and non-negative.");
        if (!std::isfinite(reconnectionRoughnessThreshold) || reconnectionRoughnessThreshold < 0.f)
            FALCOR_THROW("reconnectionRoughnessThreshold must be finite and non-negative.");
        if (!std::isfinite(reconnectionMinDistance) || reconnectionMinDistance < 0.f)
            FALCOR_THROW("reconnectionMinDistance must be finite and non-negative.");
    }

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
        else if (key == "spatialReuseTwoPass")
            spatialReuseTwoPass = value;
        else if (key == "useTemporalReuse")
            useTemporalReuse = value;
        else if (key == "temporalHistoryLength")
            temporalHistoryLength = value;
        else if (key == "reconnectionRoughnessThreshold")
            reconnectionRoughnessThreshold = value;
        else if (key == "reconnectionMinDistance")
            reconnectionMinDistance = value;
        else
            return false;
        return true;
    }

    void serialize(Properties& props) const
    {
        props["spatialReuseIteration"] = spatialReuseIteration;
        props["spatialReuseNeighborCount"] = spatialReuseNeighborCount;
        props["spatialReuseGatherRadius"] = spatialReuseGatherRadius;
        props["spatialReuseTwoPass"] = spatialReuseTwoPass;
        props["useTemporalReuse"] = useTemporalReuse;
        props["temporalHistoryLength"] = temporalHistoryLength;
        shiftMapping.serialize(props);
        props["reconnectionRoughnessThreshold"] = reconnectionRoughnessThreshold;
        props["reconnectionMinDistance"] = reconnectionMinDistance;
    }

    /// SHIFT_MAPPING_METHOD, SHIFT_MAPPING_GAUGE_MODE and USE_TEMPORAL_REUSE.
    DefineList getDefines() const
    {
        DefineList defines = shiftMapping.getDefines();
        defines.add("USE_TEMPORAL_REUSE", useTemporalReuse ? "1" : "0");
        return defines;
    }

    /// Sets the shift mapping constants (ShiftMappingCB) under `shiftmapVar`.
    void bindShiftMapping(const ShaderVar& shiftmapVar) const
    {
        shiftMapping.bindShaderData(shiftmapVar);
    }

    /// Sets a ReconnectionCriteria (Shared/Shaders/ReSTIR/PathReconstruction.slang) at `var`.
    void bindReconnectionCriteria(const ShaderVar& var) const
    {
        var["roughnessThreshold"] = reconnectionRoughnessThreshold;
        var["minDistance"] = reconnectionMinDistance;
    }

    /// Sets the spatial reuse neighbor count, radius and reconnection criteria under `spatialVar`.
    void bindSpatialReuse(const ShaderVar& spatialVar) const
    {
        spatialVar["neighborCount"] = spatialReuseNeighborCount;
        spatialVar["gatherRadius"] = spatialReuseGatherRadius;
        bindReconnectionCriteria(spatialVar["reconnection"]);
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

        dirty |= widget.checkbox("Two-pass spatial reuse", spatialReuseTwoPass);
        widget.tooltip("Compute each candidate's shifts in its own thread, then resample in a second pass: faster with "
                       "a length-aware shift (lower register use). Off runs the single-pass kernel. The results are "
                       "the same; the shift None always uses the single pass.", true);

        dirty |= widget.checkbox("Temporal reuse", useTemporalReuse);
        widget.tooltip("Resample the previous frame's reservoir (reprojected with motion vectors when the mvec input "
                       "is connected)." + temporalNote, true);

        if (useTemporalReuse)
        {
            dirty |= widget.var("History length (frames)", temporalHistoryLength, 0.f, 100000.f);
            widget.tooltip("Cap on the history's sample count, in frames of samples per pixel. 0 ignores the "
                           "history.", true);
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
                dirty |= group.var("Reconnection min distance", reconnectionMinDistance, 0.f, 1000.f);
                group.tooltip("A path can reconnect at a segment only if it is longer than this. Very short segments "
                              "make the shifted target and Jacobian nearly singular.", true);
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
    static constexpr char kReflectTypesFile[] = "RenderPasses/Shared/Shaders/ReSTIR/ReflectTypes.cs.slang";

    ref<Buffer> prevReservoirs;
    ref<Buffer> currReservoirs;
    /// W and M of each reservoir (float2), with useSummaries in prepare(): only reservoirs with W != 0 are then stored.
    ref<Buffer> prevSummaries;
    ref<Buffer> currSummaries;
    ref<Buffer> reusePairs; ///< Pair records of the two-pass spatial and temporal reuse (preparePairs).
    ref<Buffer> spatialCandidateValid; ///< Spatial neighbors' validity for the two-pass spatial reuse.
    static constexpr size_t kPairBufferBytes = size_t(512) << 20;
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
        // SceneGraphChanged comes with every animated node, also a camera animated by the scene itself; moving geometry
        // or lights also raises GeometryMoved / LightsMoved, which stay disallowed.
        auto allowedUpdates = IScene::UpdateFlags::CameraMoved | IScene::UpdateFlags::CameraPropertiesChanged |
                              IScene::UpdateFlags::CameraSwitched | IScene::UpdateFlags::SceneGraphChanged;
        if (dynamicLight)
            allowedUpdates |= IScene::UpdateFlags::LightsMoved | IScene::UpdateFlags::LightIntensityChanged |
                              IScene::UpdateFlags::LightPropertiesChanged;
        if ((scene.getUpdates() & ~allowedUpdates) != IScene::UpdateFlags::None || (!dynamicLight && lightChanged) ||
            scene.getCamera()->getApertureRadius() > 0.f)
            temporalHistoryValid = false;
    }

    /// Defines that the reservoir layout depends on: a scalar target with a single channel, and the replay data of
    /// dynamic scenes. Every program that uses the reservoirs needs them.
    static DefineList getReservoirDefines(const PathTracingConfig& pathTracing, bool isSceneDynamic)
    {
        DefineList defines;
        defines.add("RESERVOIR_SCALAR_TARGET", pathTracing.useSingleChannel ? "1" : "0");
        defines.add("IS_SCENE_DYNAMIC", isSceneDynamic ? "1" : "0");
        return defines;
    }

    /// (Re)allocates `reservoirsPerPixel` reservoirs per pixel, of the layout getReservoirDefines() gives, and with
    /// `useSummaries` their summaries (RESERVOIR_SUMMARIES); the neighbor offsets; and, with temporal reuse, the previous
    /// frame's V-buffer. A resize discards the history.
    void prepare(
        ref<Device> pDevice,
        const ref<Scene>& pScene,
        const ref<SampleGenerator>& pSampleGenerator,
        const PathTracingConfig& pathTracing,
        bool isSceneDynamic,
        uint32_t reservoirsPerPixel,
        uint2 frameDim,
        bool useTemporalReuse,
        ResourceFormat vbufferFormat,
        bool useSummaries = false
    )
    {
        if (!mpReflectTypes)
        {
            ProgramDesc desc;
            desc.addShaderModules(pScene->getShaderModules());
            desc.addTypeConformances(pScene->getTypeConformances());
            desc.addShaderLibrary(kReflectTypesFile).csEntry("main");
            mpReflectTypes = ComputePass::create(pDevice, desc, DefineList(), false);
            mReflectDefines.clear();
        }
        DefineList reflectDefines = pScene->getSceneDefines();
        reflectDefines.add(pSampleGenerator->getDefines());
        reflectDefines.add(pathTracing.getDefines());
        reflectDefines.add(getReservoirDefines(pathTracing, isSceneDynamic));
        // Set (not add) the defines to replace stale state; recreating the vars recompiles if needed. Only when they
        // change: new vars every frame cost CPU time.
        if (reflectDefines != mReflectDefines)
        {
            mpReflectTypes->getProgram()->setDefines(reflectDefines);
            mpReflectTypes->setVars(nullptr);
            mReflectDefines = reflectDefines;
        }

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
        for (ref<Buffer>* pSummaries : {&prevSummaries, &currSummaries})
        {
            if (!useSummaries)
                *pSummaries = nullptr;
            else if (!*pSummaries || (*pSummaries)->getElementCount() != reservoirCount)
            {
                temporalHistoryValid = false;
                *pSummaries = pDevice->createStructuredBuffer(sizeof(float2), reservoirCount,
                    ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal,
                    nullptr, false);
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

    /// Binds what a spatial reuse pass (`rootVar`) reads from its SpatialReuse (CB.gSpatialReuse) and does not change
    /// between iterations: the frame, the neighbor offsets, `config`'s reuse parameters, the primary hit, motion and
    /// color channels, and with `usePairs` the pair records; and `config`'s shift mapping (ShiftMappingCB).
    void bindSpatialReuse(
        const ShaderVar& rootVar,
        const RenderData& renderData,
        const PathLengthAwareReSTIRConfig& config,
        uint frameCount,
        bool useBinReuse,
        bool usePairs
    ) const
    {
        const ShaderVar var = rootVar["CB"]["gSpatialReuse"];
        var["gFrameCount"] = frameCount;
        var["gFrameDim"] = renderData.getDefaultTextureDims();
        var["neighborOffsets"] = neighborOffsets;
        var["useBinReuse"] = useBinReuse;
        config.bindSpatialReuse(var);
        InlinePass::bindChannels(var, renderData, InlinePass::kPrimaryHitAndMotionInputChannels);
        InlinePass::bindChannels(var, renderData, InlinePass::kColorOutputChannels);
        if (usePairs)
        {
            var["pairs"] = reusePairs;
            var["pairCandidateValid"] = spatialCandidateValid;
        }
        config.bindShiftMapping(rootVar["ShiftMappingCB"]);
    }

    /// (Re)allocates reusePairs, the pair records (ReusePair; `pairsVar` is a shader buffer of them) of the two-pass
    /// spatial and temporal reuse, for `candidates` records per pixel and bin: as many bins per chunk as fit in
    /// kPairBufferBytes, at least one. Returns the bins per chunk.
    uint preparePairs(ref<Device> pDevice, const ShaderVar& pairsVar, uint2 frameDim, uint candidates, uint binCount)
    {
        const size_t stride =
            pairsVar.getType()->unwrapArray()->asResourceType()->getStructType()->getSlangTypeLayout()->getStride();
        const size_t bytesPerBin = std::max<size_t>(size_t(frameDim.x) * frameDim.y * candidates * stride, 1);
        const uint chunkBins = std::clamp(uint(kPairBufferBytes / bytesPerBin), 1u, std::max(binCount, 1u));
        const uint32_t count = std::max(frameDim.x * frameDim.y * candidates * chunkBins, 1u);
        if (!reusePairs || reusePairs->getElementCount() != count || reusePairs->getStructSize() != stride)
            reusePairs = pDevice->createStructuredBuffer(pairsVar, count,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr,
                false);
        return chunkBins;
    }

    /// (Re)allocates spatialCandidateValid (`validVar` is its shader buffer): one flag per pixel and spatial neighbor.
    void prepareCandidateValid(ref<Device> pDevice, const ShaderVar& validVar, uint2 frameDim, uint neighborCount)
    {
        const uint32_t validCount = std::max(frameDim.x * frameDim.y * neighborCount, 1u);
        if (!spatialCandidateValid || spatialCandidateValid->getElementCount() != validCount)
            spatialCandidateValid = pDevice->createStructuredBuffer(validVar, validCount,
                ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr,
                false);
    }

    /// Runs `iterations` spatial reuse iterations, swapping the reservoirs before each; the passes get them and a fresh
    /// gRandomSeed in their CB.gSpatialReuse. Without `pPairPass`, an iteration is the resampling pass `pPass`. With
    /// it, spatial reuse is split into two passes (SPATIAL_REUSE_PAIRS) per iteration and chunk of `chunkBins` of the
    /// `binCount` bins: `pPairPass` with `pairsPerPixel` threads per pixel along x (a candidate each) and the chunk's
    /// bins along z, then `pPass`; both get the same seed and the chunk (pairFirstBin, pairBinCount).
    void runSpatialReuse(
        RenderContext* pRenderContext,
        const ref<ComputePass>& pPairPass,
        uint pairsPerPixel,
        const ref<ComputePass>& pPass,
        uint iterations,
        uint& randomSeed,
        uint2 frameDim,
        uint binCount = 1,
        uint chunkBins = 1
    )
    {
        const ShaderVar spatialVar = pPass->getRootVar()["CB"]["gSpatialReuse"];
        if (!pPairPass)
        {
            for (uint iteration = 0; iteration < iterations; iteration++)
            {
                swapReservoirs();
                spatialVar["gRandomSeed"] = randomSeed++;
                spatialVar["lastIteration"] = iteration + 1 == iterations;
                bindReservoirs(spatialVar);
                pPass->execute(pRenderContext, {frameDim.x, frameDim.y, 1});
            }
            return;
        }
        const ShaderVar pairVar = pPairPass->getRootVar()["CB"]["gSpatialReuse"];
        for (uint iteration = 0; iteration < iterations; iteration++)
        {
            swapReservoirs();
            for (const ShaderVar* var : {&pairVar, &spatialVar})
            {
                (*var)["gRandomSeed"] = randomSeed;
                (*var)["lastIteration"] = iteration + 1 == iterations;
                bindReservoirs(*var);
            }
            randomSeed++;
            for (uint firstBin = 0; firstBin < binCount; firstBin += chunkBins)
            {
                const uint bins = std::min(chunkBins, binCount - firstBin);
                for (const ShaderVar* var : {&pairVar, &spatialVar})
                {
                    (*var)["pairFirstBin"] = firstBin;
                    (*var)["pairBinCount"] = bins;
                }
                {
                    FALCOR_PROFILE(pRenderContext, "pairs");
                    pPairPass->execute(pRenderContext, {frameDim.x * pairsPerPixel, frameDim.y, bins});
                }
                {
                    FALCOR_PROFILE(pRenderContext, "resample");
                    pPass->execute(pRenderContext, {frameDim.x, frameDim.y, 1});
                }
            }
        }
    }

    /// The final reservoirs become the next frame's history, which stays valid with temporal reuse and a pinhole
    /// camera; keeps the V-buffer and camera position it refers to.
    void endFrame(RenderContext* pRenderContext, bool useTemporalReuse, const Scene& scene, const ref<Texture>& pVBuffer)
    {
        swapReservoirs();
        temporalHistoryValid = useTemporalReuse && scene.getCamera()->getApertureRadius() == 0.f;
        if (temporalHistoryValid)
            pRenderContext->copyResource(temporalVBuffer.get(), pVBuffer.get());
        previousCameraPosition = scene.getCamera()->getPosition();
    }

    /// Binds prevReservoirs and currReservoirs, and their summaries if allocated, to a SpatialReuse `var`.
    void bindReservoirs(const ShaderVar& var) const
    {
        var["prevReservoirs"] = prevReservoirs;
        var["currReservoirs"] = currReservoirs;
        if (prevSummaries)
        {
            var["prevSummaries"] = prevSummaries;
            var["currSummaries"] = currSummaries;
        }
    }

private:
    void swapReservoirs()
    {
        std::swap(currReservoirs, prevReservoirs);
        std::swap(currSummaries, prevSummaries);
    }

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
    DefineList mReflectDefines; ///< The defines mpReflectTypes was last set up with.
    uint2 mHistoryDim = uint2(0);
};
