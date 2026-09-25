"""Falcor graph construction and synchronized offline rendering.

Only create_testbed() imports Falcor. Configuration and CLI help work without it.
"""

from dataclasses import dataclass
import math
import numpy as np
from time import perf_counter
from tqdm import trange

from .io import save_image
from .reuse_statistics import summarize_counts, summarize_distances, validate_counts

METHODS = {
    "pt": {"plugin": "TimeGatedPathTracerInline"},
    "naive": {"plugin": "TimeGatedReSTIRInline", "shiftmapMethod": "no"},
    "ours": {"plugin": "TimeGatedReSTIRInline"},
}


@dataclass(frozen=True)
class SpatialOptions:
    neighbors: int = 5
    iterations: int = 3
    radius_pixels: float = 10.0
    roughness_threshold: float = .05
    newton_iterations: int = 5
    gauge_mode: str = "avg_grad"
    gauge_axis: tuple[float, float] = (1.0, 0.0)

    def properties(self):
        return {
            "spatialReuseNeighborCount": self.neighbors,
            "spatialReuseIteration": self.iterations,
            "spatialReuseGatherRadius": self.radius_pixels,
            "specularRoughnessThreshold": self.roughness_threshold,
            "gaugeMode": self.gauge_mode, "gaugeAxis": list(self.gauge_axis),
            "NewtonMaxIteration": self.newton_iterations,
            "isSceneDynamic": False, "useTemporalReuse": False,
        }


@dataclass(frozen=True)
class Budget:
    mode: str  # "spp" or "seconds"
    checkpoints: tuple
    spp_per_frame: int
    warmup_frames: int = 20

    def __post_init__(self):
        if self.mode not in ("spp", "seconds"):
            raise ValueError("Budget mode must be spp or seconds")
        if (type(self.spp_per_frame) is not int or type(self.warmup_frames) is not int
                or self.spp_per_frame < 1 or self.warmup_frames < 0):
            raise ValueError("SPP/frame must be positive and warm-up frames nonnegative")
        if not self.checkpoints or tuple(sorted(set(self.checkpoints))) != self.checkpoints:
            raise ValueError("Budgets must be unique and increasing")
        if any(not math.isfinite(v) or v <= 0 for v in self.checkpoints):
            raise ValueError("Budgets must be finite and positive")
        if self.mode == "spp" and any(type(v) is not int or v % self.spp_per_frame for v in self.checkpoints):
            raise ValueError("Every SPP budget must be an integer multiple of --spp-per-frame")


def create_testbed(scene):
    try:
        import falcor
    except ImportError as error:
        raise RuntimeError("Falcor bindings unavailable. Source your Falcor build's bin/setpath.sh first.") from error
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(scene.scene_file)
    if scene.camera_position is not None:
        testbed.scene.camera.position = scene.camera_position
        testbed.scene.camera.target = scene.camera_target
    testbed.resize_frame_buffer(*scene.resolution)
    testbed.scene.camera.aspectRatio = scene.resolution[0] / scene.resolution[1]
    testbed.scene.camera.apertureRadius = 0.0
    testbed.scene.camera.shutterSpeed = 0.0
    testbed.clock.pause()
    testbed.profiler.enabled = False
    return testbed


def create_graph(testbed, method, scene, spp_per_frame, spatial, *, statistics=False, sampling_method="direct",
                 specular_roughness_threshold_ellipsoid=None, triangle_sampler="LightBVH", shrink_options=None,
                 temporal_reuse=False, temporal_history_length=20.0, scene_dynamic=False, use_motion_vectors=False):
    """Construct a renderer with the selected initial sampling and scene/gate/light."""
    if triangle_sampler not in ("LightBVH", "Uniform"):
        raise ValueError("triangle_sampler must be LightBVH or Uniform")
    if statistics and method == "pt":
        raise ValueError("PT has no spatial reuse statistics")
    graph = testbed.create_render_graph(method)
    graph.create_pass("VBuffer", "VBufferRT", {
        "samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True,
    })
    # A collocated laser follows the camera; the laser pass publishes it for the tracer.
    graph.create_pass("Laser", "LaserVBufferRT", {
        "samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True,
        "laserPosition": scene.light_position, "laserDirection": scene.light_direction,
        "laserPower": scene.light_power, "laserAngle": scene.light_angle_degrees,
        "laserCollocated": scene.light_collocated, "isLightSourceLaser": scene.is_laser,
    })
    properties = {
        "samplingMethod": sampling_method, "emissiveSampler": triangle_sampler,
        "samplesPerPixel": spp_per_frame,
        "maxBounces": scene.max_bounces, "computeDirect": False,
        "useImportanceSampling": True, "useAlphaTest": True,
        "timeGateMode": "box", "timeGateWindow": scene.gate_width,
        "timeMin": scene.gate_center, "timeMax": scene.gate_center, "timeBin": 1,
        "useSingleChannel": False,
    }
    if specular_roughness_threshold_ellipsoid is not None:
        properties["specularRoughnessThresholdEllipsoid"] = specular_roughness_threshold_ellipsoid
    if method != "pt":
        properties.update(spatial.properties())
        properties["debugNewtonIterations"] = statistics
        properties["useTemporalReuse"] = temporal_reuse
        properties["isSceneDynamic"] = scene_dynamic
        properties["temporalHistoryLength"] = temporal_history_length
        properties["shiftmapMethod"] = "no" if method == "naive" else scene.shiftmap_method
    if shrink_options:
        properties.update(shrink_options)
    graph.create_pass("Tracer", METHODS[method]["plugin"], properties)
    graph.create_pass("Accumulate", "AccumulatePass", {"enabled": True, "precisionMode": "SingleCompensated"})
    for source, target in (
        ("VBuffer.vbuffer", "Tracer.vbuffer"), ("VBuffer.viewW", "Tracer.viewW"),
        ("Laser.vbuffer", "Tracer.laservbuffer"), ("Laser.viewW", "Tracer.laserviewW"),
    ):
        graph.add_edge(source, target)
    if (scene_dynamic or use_motion_vectors) and temporal_reuse and method != "pt":
        graph.add_edge("VBuffer.mvec", "Tracer.mvec")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    if statistics:
        graph.mark_output("Tracer.newtonStatistics")
        graph.mark_output("Tracer.mappingDistance")
    return graph


def timed_frame(testbed):
    start = perf_counter()
    testbed.frame()
    testbed.device.wait()  # Includes GPU completion, not just CPU submission.
    return perf_counter() - start


def read_image(graph):
    return graph.get_output("Accumulate.output").to_numpy()[..., :3].copy()


def render_method(testbed, graph, method, budget, output, *, statistics=False):
    testbed.render_graph = graph
    warmup = []
    for index in range(budget.warmup_frames):
        warmup.append({"method": method, "frame": index + 1, "seconds": timed_frame(testbed)})
    graph.get_pass("Accumulate").reset()
    testbed.device.wait()
    print(f"{method}: warm-up complete ({budget.warmup_frames} frames discarded)", flush=True)

    rows, timings = [], []
    counts = np.zeros((1, 1, 4), dtype=np.float64)
    distances = np.zeros((1, 1, 2), dtype=np.float64)
    elapsed, frames, next_checkpoint = 0.0, 0, 0
    while next_checkpoint < len(budget.checkpoints):
        duration = timed_frame(testbed)
        elapsed += duration
        frames += 1
        spp = frames * budget.spp_per_frame
        if statistics:
            # Readback/CPU aggregation are outside timed_frame(), like RGB export.
            raw_counts = validate_counts(graph.get_output("Tracer.newtonStatistics").to_numpy())
            raw_distances = graph.get_output("Tracer.mappingDistance").to_numpy()
            summarize_distances(raw_distances, raw_counts)
            counts += raw_counts.sum(axis=(0, 1), keepdims=True)
            distances += raw_distances.sum(axis=(0, 1), keepdims=True, dtype=np.float64)
        timings.append({"method": method, "frame": frames, "seconds": duration, "elapsed_seconds": elapsed})
        achieved = spp if budget.mode == "spp" else elapsed
        if achieved < budget.checkpoints[next_checkpoint]:
            continue
        filename = f"images/{method}_{frames:06d}f.npy"
        # Readback and image encoding happen AFTER this frame's timer stops.
        save_image(output / filename, read_image(graph))
        while next_checkpoint < len(budget.checkpoints) and achieved >= budget.checkpoints[next_checkpoint]:
            requested = budget.checkpoints[next_checkpoint]
            rows.append({
                "method": method, "budget_mode": budget.mode, "requested_budget": requested,
                "frames": frames, "spp": spp, "spp_per_frame": budget.spp_per_frame,
                "elapsed_seconds": elapsed,
                "overshoot_seconds": elapsed - requested if budget.mode == "seconds" else 0.0,
                "image": filename,
                **({**summarize_counts(counts), **summarize_distances(distances, counts)} if statistics else {}),
            })
            next_checkpoint += 1
        print(f"{method}: {spp} spp, {elapsed:.3f}s", flush=True)
    return rows, timings, warmup, frames


def render_reference(testbed, graph, direct_frames, maximum_frames, budget, reference_spp):
    """Continue PT after the comparison seed range, then reset accumulation for GT."""
    testbed.render_graph = graph
    # All methods discarded the same number of warm-up frames. Advancing this
    # graph beyond the largest measured frame index avoids sharing frame seeds
    # with the comparison when generating a new reference for this run.
    for _ in trange(maximum_frames - direct_frames, desc="Reference seed advance", unit="frame", dynamic_ncols=True):
        testbed.frame()
        testbed.device.wait()
    testbed.device.wait()
    graph.get_pass("Accumulate").reset()
    frames = reference_spp // budget.spp_per_frame
    for _ in trange(frames, desc=f"Reference ({reference_spp:,} spp)", unit="frame", dynamic_ncols=True):
        testbed.frame()
        testbed.device.wait()  # Progress and ETA reflect completed GPU work.
    testbed.device.wait()
    return read_image(graph)
