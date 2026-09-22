"""Offline direct PT vs naive spatial reuse vs ToF spatial reuse."""

import argparse
from dataclasses import asdict, replace
from functools import reduce
import json
import math
import os
from pathlib import Path
import platform
import shutil

from common.config import load_scene_config
from common.paths import RELEASE_OUTPUT_PATH
from common.io import load_rgb, save_csv, save_image, save_json
from common.metrics import evaluate_run, measure_error
from common.rendering import Budget, METHODS, SpatialOptions, create_graph, create_testbed, render_method, render_reference

ROOT = Path(__file__).resolve().parents[1]


def parse_args(*, default_scene=ROOT / "scenes/exp1/cornell_box.json", description=__doc__):
    parser = argparse.ArgumentParser(description=description, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--scene", type=Path, default=default_scene, help="Scene JSON; asset paths are relative to this JSON")
    parser.add_argument("--output", type=Path, required=True, help="Run directory; reruns replace comparison outputs and reuse compatible GT")
    parser.add_argument("--gate-width", type=float, required=True, help="Box gate width in scene path-length units")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--spp", nargs="+", type=int, help="Increasing exact initial-SPP checkpoints")
    group.add_argument("--seconds", nargs="+", type=float, help="Increasing synchronized rendering-time checkpoints")
    parser.add_argument("--spp-per-frame", type=int, help="Default: gcd(32, SPP budgets), or 32 for time budgets")
    parser.add_argument("--warmup-frames", type=int, default=20)
    parser.add_argument("--reference", type=Path, help="Reuse reference.npy and its adjacent reference.json from an earlier run")
    parser.add_argument("--reference-dir", type=Path, help="Shared directory for cached or newly rendered GT")
    parser.add_argument("--regenerate-reference", action="store_true", help="Render fresh GT instead of reusing the output directory's reference")
    parser.add_argument("--reference-spp", type=int, default=32768, help="SPP for a new direct-PT reference; ignored with --reference")
    parser.add_argument("--resolution", nargs=2, type=int, metavar=("WIDTH", "HEIGHT"), help="Override the scene JSON resolution")
    parser.add_argument("--neighbors", type=int, default=5)
    parser.add_argument("--iterations", type=int, default=3, help="Spatial iterations for naive and ours; 0 uses initial sample generation only")
    parser.add_argument("--radius", type=float, default=10.0, help="Spatial gathering radius in pixels")
    args = parser.parse_args()
    if args.reference and args.regenerate_reference:
        parser.error("--reference and --regenerate-reference cannot be combined")
    try:
        scene = load_scene_config(args.scene, args.resolution, gate_width=args.gate_width)
        spp_per_frame = args.spp_per_frame
        if spp_per_frame is None:
            spp_per_frame = reduce(math.gcd, args.spp, 32) if args.spp else 32
        budget = Budget("spp" if args.spp is not None else "seconds",
                        tuple(args.spp if args.spp is not None else args.seconds), spp_per_frame, args.warmup_frames)
        if args.iterations < 0:
            raise ValueError("Spatial iterations must be nonnegative (0 disables spatial reuse)")
        if args.neighbors < 1 or not math.isfinite(args.radius) or args.radius <= 0:
            raise ValueError("Neighbors and radius must be positive")
        if args.reference is None and (args.reference_spp < 1 or args.reference_spp % spp_per_frame):
            raise ValueError("--reference-spp must be positive and divisible by --spp-per-frame")
    except (ValueError, TypeError, KeyError, OSError) as error:
        parser.error(str(error))
    return args, scene, budget


def check_reference(path, scene):
    metadata = json.loads(path.with_suffix(".json").read_text())
    if metadata["scene_signature"] != scene.reference_signature():
        raise ValueError("Reference settings/scene differ from this run; generate a matching reference")
    external = metadata.get("source") == "external"
    keys = ("spp",) if external else ("spp", "spp_per_frame", "first_frame_seed_index")
    for key in keys:
        value = metadata.get(key)
        minimum = 0 if key == "first_frame_seed_index" else 1
        if type(value) is not int or value < minimum:
            raise ValueError(f"Invalid reference metadata field: {key}")
    if not external and metadata["spp"] % metadata["spp_per_frame"]:
        raise ValueError("Reference SPP must be divisible by its recorded SPP/frame")
    image = load_rgb(path, scene.resolution)
    measure_error(image, image)  # Reject an empty reference before spending GPU time.
    return image, metadata


def find_reference(output, scene, explicit=None, regenerate=False):
    """Explicit references must be valid; an unusable local cache is regenerated."""
    if explicit is not None:
        return check_reference(explicit.resolve(), scene), str(explicit.resolve())
    cached = output / "reference.npy"
    if not regenerate and cached.is_file():
        try:
            reference = check_reference(cached, scene)
        except (ValueError, OSError, KeyError, TypeError, EOFError) as error:
            print(f"Saved GT cannot be reused ({error}); generating new GT.", flush=True)
        else:
            print(f"Reusing GT: {cached}", flush=True)
            return reference, str(cached)
    return None, "generated after comparison"


def clear_comparison_outputs(output, keep_reference):
    """Clear generated run files while preserving compatible GT and unrelated files."""
    output.mkdir(parents=True, exist_ok=True)
    images = output / "images"
    if images.is_symlink():
        images.unlink()
    elif images.exists():
        shutil.rmtree(images)
    names = ["run.json", "checkpoints.csv", "frame_times.csv", "warmup_times.csv", "errors.csv"]
    if not keep_reference:
        names.extend(["reference.npy", "reference.json", "reference.png"])
    for name in names:
        (output / name).unlink(missing_ok=True)


def main(*, variants=None, default_scene=ROOT / "scenes/exp1/cornell_box.json",
         experiment="offline_rendering_with_spatial_reuse_comparison", description=__doc__, statistics=False, sampling_methods=None,
         evaluate_errors=True, shrink_options=None):
    # Each label selects an existing integrator and optional SpatialOptions overrides.
    if variants is None:
        variants = {method: (method, {}) for method in METHODS}
    sampling_methods = sampling_methods or {}
    shrink_options = shrink_options or {}
    args, scene, budget = parse_args(default_scene=default_scene, description=description)
    output = args.output.resolve()
    reference_dir = (getattr(args, "reference_dir", None) or
                     RELEASE_OUTPUT_PATH / "reference" / scene.name / f"{scene.gate_width:.4f}").resolve()
    spatial = SpatialOptions(neighbors=args.neighbors, iterations=args.iterations, radius_pixels=args.radius)
    existing_reference, reference_source = find_reference(reference_dir, scene, args.reference, args.regenerate_reference)
    testbed = create_testbed(scene)
    clear_comparison_outputs(output, keep_reference=existing_reference is not None)
    manifest = {
        "experiment": experiment, "scene": asdict(scene),
        "budget": asdict(budget), "spatial": asdict(spatial),
        "methods": {
            label: {**METHODS[method], "renderer": method, "samplingMethod": sampling_methods.get(label, "direct"), **({
                **replace(spatial, **overrides).properties(),
                "shiftmapMethod": "no" if method == "naive" else scene.shiftmap_method,
            } if method != "pt" else {})}
            for label, (method, overrides) in variants.items()
        },
        "initial_sampling": sampling_methods or "direct", "temporal_reuse": False,
        "shrink_options": shrink_options,
        "triangle_sampler": "LightBVH",
        "mapping_statistics": statistics,
        "mapping_distance_definition": "Euclidean coordinate/world distance sums over measured frames and spatial iterations; means per pre-visibility mapping success, including zero-distance identity maps" if statistics else None,
        "timing_includes_diagnostics": statistics,
        "timing": "Synchronized wall time per full frame; excludes warm-up, readback, I/O, GT, and error evaluation",
        "time_budget_policy": "First completed frame at/after budget; see elapsed_seconds and overshoot_seconds",
        "reference_source": reference_source,
        "reference_file": os.path.relpath(reference_dir / "reference.npy", output),
        "environment": {"python": platform.python_version(), "adapter": testbed.device.info.adapter_name,
                        "graphics_api": testbed.device.info.api_name},
        "status": "rendering",
    }
    save_json(output / "run.json", manifest)
    print(f"Scene: {scene.name}; {budget.mode} budgets: {budget.checkpoints}; {budget.spp_per_frame} spp/frame", flush=True)
    rows, timings, warmup = [], [], []
    direct_graph, direct_frames, maximum_frames = None, 0, 0
    for label, (method, overrides) in variants.items():
        graph = create_graph(testbed, method, scene, budget.spp_per_frame, replace(spatial, **overrides), statistics=statistics, sampling_method=sampling_methods.get(label, "direct"), shrink_options=shrink_options.get(label))
        method_rows, method_times, warmup_times, frames = render_method(testbed, graph, label, budget, output, statistics=statistics)
        if sampling_methods:
            for row in method_rows:
                row.update(renderer=method, sampling_method=sampling_methods.get(label, "direct"))
        rows.extend(method_rows)
        timings.extend(method_times)
        warmup.extend(warmup_times)
        maximum_frames = max(maximum_frames, frames)
        if method == "pt" and sampling_methods.get(label, "direct") == "direct":
            direct_graph, direct_frames = graph, frames
        save_csv(output / "checkpoints.csv", rows)
        save_csv(output / "frame_times.csv", timings)
        if warmup:
            save_csv(output / "warmup_times.csv", warmup)

    if existing_reference is None:
        if direct_graph is None:
            direct_graph = create_graph(testbed, "pt", scene, budget.spp_per_frame, spatial)
            testbed.render_graph = direct_graph
            # Match the comparison seed range before render_reference advances past it.
            for _ in range(budget.warmup_frames):
                testbed.frame()
            testbed.device.wait()
        reference = render_reference(testbed, direct_graph, direct_frames, maximum_frames, budget, args.reference_spp)
        measure_error(reference, reference)
        metadata = {
            "scene_signature": scene.reference_signature(), "spp": args.reference_spp,
            "spp_per_frame": budget.spp_per_frame,
            "first_frame_seed_index": budget.warmup_frames + maximum_frames,
        }
    else:
        reference, metadata = existing_reference
    if existing_reference is None or args.reference is not None or reference_dir == output:
        reference_dir.mkdir(parents=True, exist_ok=True)
        save_image(reference_dir / "reference.npy", reference)
        save_json(reference_dir / "reference.json", metadata)
    errors = evaluate_run(output) if evaluate_errors else []
    manifest["status"] = "complete"
    manifest["reference_spp"] = metadata["spp"]
    save_json(output / "run.json", manifest)
    if not evaluate_errors:
        print(f"\nSaved images, reference, and timing data to {output}. Run the plotting script to calculate errors.", flush=True)
        return
    if any(row["reference_frame_overlap"] for row in errors):
        print("Note: cached reference frame indices overlap this comparison. Error estimates can be correlated; "
              "use --regenerate-reference to generate a reference after the comparison.")
    print("\nmethod          spp       seconds    RMSE          relative_MSE  MAPE (fraction)")
    for row in errors:
        print(f"{row['method']:14s}  {int(row['spp']):8d}  {float(row['elapsed_seconds']):8.3f}  "
              f"{row['rmse']:12.6g}  {row['relative_mse']:12.6g}  {row['mape']:.6g}")
    if statistics:
        print("\nMapping distances (mean per pre-visibility mapping success; warm-up excluded)")
        print("method          seconds    mean_xi_distance  mean_world_distance  mapping_successes")
        for row in errors:
            xi = f"{float(row['mean_xi_distance']):.6g}" if row['mean_xi_distance'] else "N/A"
            world = f"{float(row['mean_world_distance']):.6g}" if row['mean_world_distance'] else "N/A"
            print(f"{row['method']:14s}  {float(row['elapsed_seconds']):8.3f}  {xi:16s}  {world:19s}  {row['mapping_success_count']}")
    print(f"\nSaved images, timing data, and errors.csv to {output}", flush=True)


if __name__ == "__main__":
    main()
