"""Export RGB, Newton counters and mapping distances for naive reuse and ours; no GT rendering."""

import argparse
from dataclasses import asdict
import math
from pathlib import Path

import numpy as np

from common.config import load_scene_config
from common.io import save_csv, save_json, save_image
from common.rendering import SpatialOptions, create_graph, create_testbed, timed_frame
from common.reuse_statistics import CHANNELS, DISTANCE_CHANNELS, summarize_counts, summarize_distances, validate_counts

ROOT = Path(__file__).resolve().parents[1]


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", type=Path, default=ROOT / "scenes/exp2/cornell_box_dragon_diffuse.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--methods", nargs="+", choices=("naive_reuse", "ours"),
                        default=["naive_reuse", "ours"], help="Methods to render (exp3 uses ours only)")
    parser.add_argument("--gate-width", type=float, required=True)
    budget = parser.add_mutually_exclusive_group()
    budget.add_argument("--seconds", type=float, help="Synchronized GPU-complete frame time; default 3 seconds")
    budget.add_argument("--frames", type=int, help="Use an exact number of measured frames instead")
    parser.add_argument("--spp-per-frame", type=int, default=32)
    parser.add_argument("--neighbors", type=int, default=5)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--radius", type=float, default=10.)
    parser.add_argument("--resolution", type=int, nargs=2)
    args = parser.parse_args()
    if args.seconds is None and args.frames is None:
        args.seconds = 3.
    try:
        scene = load_scene_config(args.scene, args.resolution, gate_width=args.gate_width)
        if len(set(args.methods)) != len(args.methods):
            raise ValueError("methods must be unique")
        for name in ("spp_per_frame", "neighbors", "iterations"):
            if getattr(args, name) < 1:
                raise ValueError(f"{name} must be positive for reuse statistics")
        if args.frames is not None and args.frames < 1:
            raise ValueError("frames must be positive")
        if args.seconds is not None and (not math.isfinite(args.seconds) or args.seconds <= 0):
            raise ValueError("seconds must be finite and positive")
        if not math.isfinite(args.radius) or args.radius <= 0:
            raise ValueError("radius must be finite and positive")
    except (ValueError, TypeError, KeyError, OSError) as error:
        parser.error(str(error))
    return args, scene


def main():
    args, scene = parse_args()
    spatial = SpatialOptions(neighbors=args.neighbors, iterations=args.iterations, radius_pixels=args.radius)
    testbed = create_testbed(scene)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Only replace this exporter's files. Never touch rendering/GT outputs.
    for name in ("statistics.csv", "frame_times.csv", "warmup_times.csv", "naive_reuse_counts.npy", "ours_counts.npy"):
        (output / name).unlink(missing_ok=True)
    for label in ("naive_reuse", "ours"):
        for suffix in ("mapping_distance.npy", "rgb.npy", "rgb.png"):
            (output / f"{label}_{suffix}").unlink(missing_ok=True)
    manifest = {
        "status": "rendering", "scene": asdict(scene), "spatial": asdict(spatial), "methods": args.methods,
        "seconds": args.seconds, "frames": args.frames, "spp_per_frame": args.spp_per_frame,
        "channels": CHANNELS, "distance_channels": DISTANCE_CHANNELS,
        "mapping_distance": "Sum of Euclidean coordinate/world displacements for pre-visibility successful solves; identity maps contribute zero; means divide by mapping_success_count",
        "counts": "Sum over measured frames, pixels and spatial iterations; dedicated uint4 output",
        "attempts": "Eligible neighbor-to-pixel candidates reaching mapping after prefix reconstruction; includes naive/identity mappings; excludes canonical evaluation",
        "actual_success": "Positive finite target contribution after geometry, material eligibility, gate and visibility; not reservoir selection",
        "mapping_success": "Newton solve success before visibility, or a valid naive/identity mapping without Newton",
        "timing": "Instrumented synchronized frame time; includes first-frame initialization/compilation; excludes readback and file I/O. Not a normal-render performance comparison.",
    }
    save_json(output / "statistics_run.json", manifest)
    rows, timings = [], []
    for label in args.methods:
        method = "naive" if label == "naive_reuse" else "ours"
        graph = create_graph(testbed, method, scene, args.spp_per_frame, spatial, statistics=True)
        testbed.render_graph = graph
        totals = np.zeros((scene.resolution[1], scene.resolution[0], 4), dtype=np.uint64)
        distances = np.zeros(totals.shape[:2] + (2,), dtype=np.float64)
        elapsed, frames = 0., 0
        while (frames < args.frames if args.frames is not None else elapsed < args.seconds):
            duration = timed_frame(testbed)
            elapsed += duration
            frames += 1
            raw = validate_counts(graph.get_output("Tracer.newtonStatistics").to_numpy())
            if raw.shape != totals.shape:
                raise ValueError(f"Unexpected counter dimensions: {raw.shape}")
            totals += raw.astype(np.uint64)
            raw_distances = graph.get_output("Tracer.mappingDistance").to_numpy()
            summarize_distances(raw_distances, raw)  # Validate shape and finite/nonnegative values.
            distances += raw_distances
            timings.append({"method": label, "frame": frames, "seconds": duration, "elapsed_seconds": elapsed})
        filename = f"{label}_counts.npy"
        np.save(output / filename, totals)  # All four raw channels; no tone mapping or alpha conversion.
        distance_filename = f"{label}_mapping_distance.npy"
        np.save(output / distance_filename, distances)
        save_image(output / f"{label}_rgb.npy", graph.get_output("Accumulate.output").to_numpy()[..., :3].copy())
        row = {"method": label, "gate_width": scene.gate_width,
               "shiftmap_method": "no" if method == "naive" else scene.shiftmap_method,
               "frames": frames, "spp": frames * args.spp_per_frame,
               "elapsed_seconds": elapsed, "counts_file": filename, "mapping_distance_file": distance_filename,
               **summarize_counts(totals), **summarize_distances(distances, totals)}
        rows.append(row)
        save_csv(output / "statistics.csv", rows)
        save_csv(output / "frame_times.csv", timings)
        rate = row["actual_success_rate"]
        print(f"{label}: {row['actual_success_count']}/{row['attempt_count']} = "
              f"{rate if rate is not None else 'undefined (no attempts)'}", flush=True)
    manifest["status"] = "complete"
    save_json(output / "statistics_run.json", manifest)


if __name__ == "__main__":
    main()
