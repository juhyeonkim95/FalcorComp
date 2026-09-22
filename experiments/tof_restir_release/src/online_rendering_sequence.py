"""Headless sequence comparison with independently animated gate, camera, and light."""

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import shutil
import subprocess

import numpy as np
from tqdm import trange

from common.config import load_scene_config
from common.io import save_csv, save_image, save_json
from common.paths import RELEASE_OUTPUT_PATH
from common.sequence_calibration import next_spp
from common.sequence_motion import apply_camera_motion, make_camera_motion, sequence_reference_path, sequence_configs_match, make_laser_motion, apply_sequence_motion, configure_sequence_motion, sequence_light_is_dynamic
from common.rendering import METHODS, SpatialOptions, create_graph, create_testbed, read_image, timed_frame


def encode_video(ffmpeg, output, frames, fps):
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-framerate", str(fps), "-start_number", "0",
                    "-i", str(output / "images/frame_%04d.png"), "-frames:v", str(frames),
                    "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(output / "sequence.mp4")], check=True)


def summarize_timings(rows):
    measured = [row["render_ms"] for row in rows if row["included_in_timing_summary"]]
    return {"method": rows[0]["method"], "measured_frames": len(measured),
            "excluded_frames": len(rows) - len(measured),
            "mean_frame_ms": float(np.mean(measured)), "median_frame_ms": float(np.median(measured)),
            "p95_frame_ms": float(np.percentile(measured, 95))}


def create_sequence_graph(testbed, scene, method, args):
    motion = getattr(args, "camera_motion", None)
    args.light_collocated = scene.light_collocated
    apply_sequence_motion(testbed, args, 0)
    spatial = SpatialOptions(iterations=args.iterations, neighbors=args.neighbors)
    graph = create_graph(testbed, method, scene, args.spp, spatial, sampling_method="direct",
                         temporal_reuse=method != "pt", temporal_history_length=args.temporal_history_length,
                         scene_dynamic=sequence_light_is_dynamic(scene, args), use_motion_vectors=motion is not None)
    testbed.render_graph = graph
    return graph


def time_sequence(testbed, scene, method, args):
    # A new graph resets tracer RNG/frame counters and ReSTIR history to frame zero.
    graph = create_sequence_graph(testbed, scene, method, args)
    tracer = graph.get_pass("Tracer")
    accumulator = graph.get_pass("Accumulate")
    motion = getattr(args, "camera_motion", None)
    centers = (np.full(args.frames, scene.gate_center) if getattr(scene, "gate_min", None) is None else
               np.linspace(scene.gate_min, scene.gate_max, args.frames, endpoint=False))
    print(f"{method}: timing {args.frames} frames without image export", flush=True)
    rows = []
    # No readback, file writes, video encoding, or progress updates between frames.
    for frame, center in enumerate(centers):
        apply_sequence_motion(testbed, args, frame, graph)
        tracer.set_time_gate_info(float(center), float(center), 1)
        accumulator.reset()
        rows.append({"method": method, "frame": frame,
                     "render_ms": timed_frame(testbed) * 1000.,
                     "included_in_timing_summary": frame >= args.timing_skip_frames})
    return rows


def render_sequence(testbed, scene, method, args, output, ffmpeg, reference_config=None, timing_rows=None):
    graph = create_sequence_graph(testbed, scene, method, args)
    temporal = method != "pt"
    tracer = graph.get_pass("Tracer")
    accumulator = graph.get_pass("Accumulate")
    images = output / "images"
    images.mkdir(parents=True, exist_ok=True)
    for pattern in ("frame_*.png", "frame_*.npy"):
        for path in images.glob(pattern):
            path.unlink()
    for name in ("sequence.mp4", "frames.csv"):
        (output / name).unlink(missing_ok=True)
    motion = getattr(args, "camera_motion", None)
    centers = (np.full(args.frames, scene.gate_center) if getattr(scene, "gate_min", None) is None else
               np.linspace(scene.gate_min, scene.gate_max, args.frames, endpoint=False))
    manifest = {
        "experiment": "online_rendering_sequence", "scene": asdict(scene),
        "method": method, "renderer": METHODS[method]["plugin"], "sampling_method": "direct",
        "temporal_reuse": temporal,
        "temporal_history_length": args.temporal_history_length if temporal else None,
        "incoming_history_mass_cap": args.temporal_history_length * args.spp if temporal else None,
        "spatial_iterations": args.iterations if temporal else 0,
        "spatial_neighbors": args.neighbors if temporal else 0,
        "shiftmap_method": ("no" if method == "naive" else scene.shiftmap_method) if temporal else None,
        "gate_min": scene.gate_min, "gate_max": scene.gate_max,
        "frames": args.frames, "spp_per_frame": args.spp, "video_fps": args.fps,
        "gate_endpoint_included": False,
        "accumulate_across_frames": False,
        "preview": "Reinhard + sRGB; identical exposure for every frame and method",
        "timing": ("Separate fresh sequence run; synchronized full-frame wall time in milliseconds; "
                   "no image readback, disk export or progress updates during the timed sequence")
                  if reference_config is None else "Not measured for GT",
        "timing_separate_run": reference_config is None,
        "timing_skip_frames": args.timing_skip_frames,
        "status": "rendering",
    }
    if motion is not None:
        manifest["camera_motion"] = motion
        manifest["scene_dynamic"] = method != "pt" and sequence_light_is_dynamic(scene, args)
    if getattr(args, "laser_motion", None) is not None:
        manifest["laser_motion"] = args.laser_motion
        manifest["scene_dynamic"] = method != "pt" and sequence_light_is_dynamic(scene, args)
    if reference_config is not None:
        manifest["reference_config"] = reference_config
    save_json(output / "run.json", manifest)
    rows = []
    for frame in trange(args.frames, desc=method, unit="frame", dynamic_ncols=True):
        apply_sequence_motion(testbed, args, frame, graph)
        center = float(centers[frame])
        # Gate i is min + i * (max - min) / frames; preserve tprev in ReSTIR.
        tracer.set_time_gate_info(center, center, 1)
        accumulator.reset()  # Reset only image averaging, not the tracer's history.
        testbed.frame()
        testbed.device.wait()
        image = f"images/frame_{frame:04d}.npy"
        save_image(output / image, read_image(graph))
        rows.append({"method": method, "frame": frame, "gate_center": center,
                     "gate_width": args.gate_width, "spp": args.spp,
                     "image": image})
    save_csv(output / "frames.csv", rows)
    summary = None
    if reference_config is None:
        manifest["status"] = "timing"
        save_json(output / "run.json", manifest)
        timings = timing_rows if timing_rows is not None else time_sequence(testbed, scene, method, args)
        if len(timings) != len(rows):
            raise ValueError("Timing and exported sequence lengths differ")
        for row, timing in zip(rows, timings):
            row.update(timing)
        summary = summarize_timings(rows)
        save_csv(output / "frames.csv", rows)
        print(f"{method}: {summary['mean_frame_ms']:.3f} ms/frame "
              f"({args.timing_skip_frames} initial frames excluded)", flush=True)
    encode_video(ffmpeg, output, args.frames, args.fps)
    manifest.update(status="complete", timing_summary=summary)
    save_json(output / "run.json", manifest)
    print(f"Saved {output}", flush=True)
    return rows, summary


def render_reference_sequence(testbed, scene, args, ffmpeg):
    motion = getattr(args, "camera_motion", None)
    output = sequence_reference_path(scene, motion, getattr(args, "laser_motion", None))
    config = {"scene_signature": scene.reference_signature(), "gate_min": scene.gate_min,
              "gate_max": scene.gate_max, "frames": args.frames, "video_fps": args.fps,
              "gate_endpoint_included": False}
    if motion is not None:
        config["camera_motion"] = motion
    if getattr(args, "laser_motion", None) is not None:
        config["laser_motion"] = args.laser_motion
    manifest_path = output / "run.json"
    if manifest_path.is_file():
        try:
            saved = json.loads(manifest_path.read_text())
            complete = all((output / "images" / f"frame_{frame:04d}.{extension}").is_file()
                           for frame in range(args.frames) for extension in ("png", "npy"))
            if (saved.get("status") == "complete" and sequence_configs_match(saved.get("reference_config", {}), config)
                    and saved.get("spp_per_frame", 0) >= args.reference_spp and complete
                    and (output / "frames.csv").is_file() and (output / "sequence.mp4").is_file()):
                print(f"Reusing reference sequence: {output}", flush=True)
                return output
        except (ValueError, OSError):
            pass
    # One configuration per scene/gate folder; render_sequence replaces its generated files.
    reference_args = argparse.Namespace(**vars(args))
    reference_args.spp = args.reference_spp
    reference_args.timing_skip_frames = 0
    print(f"Rendering PT reference sequence at {args.reference_spp} SPP/frame: {output}", flush=True)
    render_sequence(testbed, scene, "pt", reference_args, output, ffmpeg, reference_config=config)
    return output


def calibrate_sequences(testbed, scene, args, output):
    """Measure an equal-SPP baseline, then allow at most three adjustments per competitor."""
    trials = {method: [] for method in args.methods}
    all_timings = []
    measured = {}

    def measure(method, spp, attempt):
        options = argparse.Namespace(**vars(args))
        options.spp = spp
        rows = time_sequence(testbed, scene, method, options)
        summary = summarize_timings(rows)
        trial = {**summary, "spp": spp, "attempt": attempt}
        trials[method].append(trial)
        measured[(method, spp)] = rows
        all_timings.extend({**row, "spp": spp, "attempt": attempt} for row in rows)
        save_csv(output / "calibration_trials.csv", [item for group in trials.values() for item in group])
        save_csv(output / "calibration_frame_times.csv", all_timings)
        print(f"Calibration {method}: {spp} SPP, {trial['mean_frame_ms']:.3f} ms", flush=True)
        return trial

    for method in args.methods:
        measure(method, args.spp, 0)
    target = trials["ours"][0]["mean_frame_ms"]
    selected = {}
    for method in args.methods:
        if method != "ours":
            for attempt in range(1, args.calibration_runs + 1):
                best = min(trials[method], key=lambda trial: abs(trial["mean_frame_ms"] - target))
                if abs(best["mean_frame_ms"] / target - 1.) <= args.timing_tolerance:
                    break
                spp = next_spp(trials[method], target)
                if spp is None:
                    break
                measure(method, spp, attempt)
        best = min(trials[method], key=lambda trial: abs(trial["mean_frame_ms"] - target))
        selected[method] = {**best, "target_frame_ms": target,
                            "relative_time_error": best["mean_frame_ms"] / target - 1.,
                            "within_tolerance": abs(best["mean_frame_ms"] / target - 1.) <= args.timing_tolerance}
    save_json(output / "calibration.json", {"target_method": "ours", "fixed_spp": args.spp,
              "target_frame_ms": target, "tolerance": args.timing_tolerance,
              "max_adjustment_runs": args.calibration_runs, "selected": selected, "trials": trials})
    for method, trial in selected.items():
        print(f"Selected {method}: {trial['spp']} SPP, {trial['mean_frame_ms']:.3f} ms "
              f"({trial['relative_time_error']:+.1%} vs ours; within tolerance: {trial['within_tolerance']})", flush=True)
    return selected, measured


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", type=Path, required=True, help="Scene JSON with fixed/ranged gate and optional camera/light motion")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--methods", nargs="+", choices=list(METHODS), default=list(METHODS))
    parser.add_argument("--gate-width", type=float, default=.01)
    parser.add_argument("--frames", type=int, default=100)
    parser.add_argument("--spp", type=int, default=32)
    parser.add_argument("--reference-spp", type=int, default=1024)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--neighbors", type=int, default=3)
    parser.add_argument("--temporal-history-length", type=float, default=20.)
    parser.add_argument("--timing-skip-frames", type=int, default=5)
    parser.add_argument("--match-time", action="store_true", help="Calibrate competitor SPP to ours before image generation")
    parser.add_argument("--calibration-runs", type=int, default=3, help="Maximum adjustments after the equal-SPP baseline")
    parser.add_argument("--timing-tolerance", type=float, default=.05)
    args = parser.parse_args()
    args.methods = list(dict.fromkeys(args.methods))
    if args.match_time and "ours" not in args.methods:
        parser.error("Time matching requires ours as the fixed target")
    if not 0 <= args.calibration_runs <= 3 or not 0 < args.timing_tolerance < 1:
        parser.error("Use 0–3 calibration runs and a timing tolerance between 0 and 1")
    if args.frames < 2 or args.spp < 1 or args.reference_spp < 1 or args.fps < 1:
        parser.error("At least two frames and positive SPP/FPS are required")
    if not 0 <= args.timing_skip_frames < args.frames:
        parser.error("timing-skip-frames must leave at least one measured frame")
    if args.iterations < 0 or args.neighbors < 1:
        parser.error("Spatial iterations must be nonnegative and neighbor count positive")
    if not np.isfinite(args.temporal_history_length) or args.temporal_history_length <= 0:
        parser.error("Temporal history length must be finite and positive")
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        parser.error("ffmpeg is required to encode the videos")
    scene = load_scene_config(args.scene, gate_width=args.gate_width)
    if any(size % 2 for size in scene.resolution):
        parser.error("Video dimensions in the scene JSON must be even")
    if scene.gate_min is not None:
        scene.gate_center = scene.gate_min
    testbed = create_testbed(scene)
    configure_sequence_motion(scene, testbed.scene.camera, args)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ("frame_times.csv", "timing_summary.csv"):
        (output / name).unlink(missing_ok=True)
    selected, measured = calibrate_sequences(testbed, scene, args, output) if args.match_time else ({}, {})
    timings, summaries = [], []
    for method in args.methods:
        options = argparse.Namespace(**vars(args))
        options.spp = selected[method]["spp"] if args.match_time else args.spp
        timing_rows = measured[(method, options.spp)] if args.match_time else None
        rows, summary = render_sequence(testbed, scene, method, options, output / method, ffmpeg, timing_rows=timing_rows)
        summary["spp"] = options.spp
        if args.match_time:
            summary.update(target_frame_ms=selected[method]["target_frame_ms"],
                           relative_time_error=selected[method]["relative_time_error"],
                           within_tolerance=selected[method]["within_tolerance"])
        timings.extend({**row, "image": f"{method}/{row['image']}"} for row in rows)
        summaries.append(summary)
        save_csv(output / "frame_times.csv", timings)
        save_csv(output / "timing_summary.csv", summaries)
    render_reference_sequence(testbed, scene, args, ffmpeg)


if __name__ == "__main__":
    main()
