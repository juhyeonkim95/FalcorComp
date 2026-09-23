"""Application 1: scanning NLOS (SNLOS) rendering with PT / naive reuse / ours at equal time.

For every hidden voxel (serpentine scan of a grid on the hidden plane), the gate is set to
2 * tau and the laser visits the points of the voxel's illumination ellipse, one frame each
(see common/snlos.py). Initial samples use ellipsoidal connection without MIS. Naive and ours
use temporal reuse across these frames (the laser moves, so ReSTIR reevaluates suffix lighting)
plus spatial reuse. As in exp7, PT and naive SPP are calibrated so that their mean frame time
matches ours at the fixed SPP, measured over the first voxels of the scan without readback.

Saves, per method, frames/voxel_XXXX.npz with the red-channel radiance of each laser position
(rows top to bottom, as rendered), and timing/manifests. Plotting and reconstruction read these.
The scene JSON's gate_center is only a placeholder: each voxel sets its own gate.
"""

import argparse
from dataclasses import asdict, replace
from pathlib import Path

import numpy as np
from tqdm import tqdm

from common.config import load_scene_config
from common.io import save_csv, save_json
from common.rendering import SpatialOptions, create_graph, create_testbed, timed_frame
from common.sequence_calibration import next_spp
from common.snlos import SnlosSetup, ellipse_points_on_wall

METHOD_LABELS = {"pt": "PT", "naive": "Naive reuse", "ours": "Ours"}


def scan_frames(setup, voxel_limit=None):
    """[(voxel index, gate center, laser points)] in render order; voxels without an ellipse are skipped."""
    voxels = setup.voxel_centers()
    frames = []
    for voxel_index in setup.render_order():
        voxel = voxels[voxel_index]
        tau = setup.path_length(voxel)
        try:
            points = ellipse_points_on_wall(setup.origin, voxel, tau, setup.ellipse_samples)
        except ValueError as error:
            print(f"[voxel {voxel_index}] no illumination ellipse: {error}", flush=True)
            continue
        frames.append((int(voxel_index), 2.0 * tau, points))
        if voxel_limit is not None and len(frames) >= voxel_limit:
            break
    return frames


def laser_direction(origin, point):
    direction = np.asarray(point, dtype=np.float64) - origin
    return (direction / np.linalg.norm(direction)).tolist()


def build_graph(testbed, scene, method, spp, args):
    spatial = SpatialOptions(iterations=args.iterations, neighbors=args.neighbors, radius_pixels=args.radius)
    reuse = method != "pt"
    graph = create_graph(testbed, method, scene, spp, spatial, sampling_method="ellipsoidal",
                         triangle_sampler="LightBVH", temporal_reuse=reuse,
                         temporal_history_length=args.temporal_history_length, scene_dynamic=reuse)
    testbed.render_graph = graph
    return graph


def run_scan(testbed, scene, setup, method, spp, args, scan, output=None):
    """Render the scan with a fresh graph (fresh ReSTIR history). Returns per-frame timing rows.

    With output=None nothing is read back or written, so the timings are not perturbed.
    """
    graph = build_graph(testbed, scene, method, spp, args)
    tracer, laser, accumulator = graph.get_pass("Tracer"), graph.get_pass("Laser"), graph.get_pass("Accumulate")
    origin = np.asarray(setup.origin, dtype=np.float64)
    rows = []
    frame_index = 0
    for voxel_index, gate, points in tqdm(scan, desc=f"{method} ({spp} spp)", unit="voxel",
                                          dynamic_ncols=True, disable=output is None):
        # A constant gate per voxel; ReSTIR keeps tprev across the voxel change.
        tracer.set_time_gate_info(float(gate), float(gate), 1)
        images = []
        for sample, point in enumerate(points):
            laser.update_laser_info(origin.tolist(), laser_direction(origin, point))
            accumulator.reset()  # Each frame is its own image; the tracer keeps its history.
            milliseconds = timed_frame(testbed) * 1000.0
            if output is not None:
                images.append(graph.get_output("Accumulate.output").to_numpy()[..., 0].copy())
            rows.append({"method": method, "frame": frame_index, "voxel": voxel_index, "laser_sample": sample,
                         "gate_center": float(gate), "spp": spp, "render_ms": milliseconds,
                         "included_in_timing_summary": frame_index >= args.timing_skip_frames})
            frame_index += 1
        if output is not None:
            images = np.asarray(images, dtype=np.float32)
            if not np.isfinite(images).all():
                raise ValueError(f"{method}: non-finite radiance at voxel {voxel_index}")
            np.savez_compressed(output / "frames" / f"voxel_{voxel_index:04d}.npz", images=images,
                                laser_points=np.asarray(points), gate_center=np.float64(gate))
    return rows


def summarize(rows):
    measured = [row["render_ms"] for row in rows if row["included_in_timing_summary"]]
    return {"measured_frames": len(measured), "excluded_frames": len(rows) - len(measured),
            "mean_frame_ms": float(np.mean(measured)), "median_frame_ms": float(np.median(measured)),
            "p95_frame_ms": float(np.percentile(measured, 95))}


def calibrate(testbed, scene, setup, args, output):
    """exp7 procedure on the first scan voxels: fix ours, adjust PT/naive SPP (at most 3 runs)."""
    scan = scan_frames(setup, args.calibration_voxels)
    options = argparse.Namespace(**vars(args))
    options.timing_skip_frames = min(args.timing_skip_frames, len(scan) * setup.ellipse_samples - 1)
    trials = {method: [] for method in args.methods}

    def measure(method, spp, attempt):
        summary = summarize(run_scan(testbed, scene, setup, method, spp, options, scan))
        trials[method].append({**summary, "spp": spp, "attempt": attempt})
        save_csv(output / "calibration_trials.csv", [trial for group in trials.values() for trial in group])
        print(f"Calibration {method}: {spp} SPP, {summary['mean_frame_ms']:.3f} ms/frame", flush=True)

    for method in args.methods:
        measure(method, args.spp, 0)
    target = trials["ours"][0]["mean_frame_ms"]
    selected = {}
    for method in args.methods:
        if method != "ours":
            for attempt in range(1, args.calibration_runs + 1):
                best = min(trials[method], key=lambda trial: abs(trial["mean_frame_ms"] - target))
                if abs(best["mean_frame_ms"] / target - 1.0) <= args.timing_tolerance:
                    break
                spp = next_spp(trials[method], target)
                if spp is None:
                    break
                measure(method, spp, attempt)
        best = min(trials[method], key=lambda trial: abs(trial["mean_frame_ms"] - target))
        selected[method] = {**best, "target_frame_ms": target,
                            "relative_time_error": best["mean_frame_ms"] / target - 1.0,
                            "within_tolerance": abs(best["mean_frame_ms"] / target - 1.0) <= args.timing_tolerance}
        print(f"Selected {method}: {best['spp']} SPP ({selected[method]['relative_time_error']:+.1%} vs ours)", flush=True)
    save_json(output / "calibration.json", {"target_method": "ours", "fixed_spp": args.spp, "target_frame_ms": target,
              "calibration_voxels": len(scan), "tolerance": args.timing_tolerance,
              "max_adjustment_runs": args.calibration_runs, "selected": selected, "trials": trials})
    return {method: trial["spp"] for method, trial in selected.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scene", type=Path, required=True, help="scenes/application_1/<object>.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--methods", nargs="+", choices=list(METHOD_LABELS), default=list(METHOD_LABELS))
    parser.add_argument("--gate-width", type=float, default=0.01)
    parser.add_argument("--spp", type=int, default=32, help="fixed SPP of ours; starting SPP of PT and naive")
    parser.add_argument("--temporal-history-length", type=float, default=5.0)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--neighbors", type=int, default=3)
    parser.add_argument("--radius", type=float, default=5.0, help="spatial gather radius in pixels")
    parser.add_argument("--grid-res", type=int, default=SnlosSetup.grid_res)
    parser.add_argument("--ellipse-samples", type=int, default=SnlosSetup.ellipse_samples)
    parser.add_argument("--voxel-limit", type=int, default=None, help="render only the first N scan voxels (testing)")
    parser.add_argument("--match-time", action="store_true", help="calibrate PT/naive SPP to ours before rendering")
    parser.add_argument("--calibration-voxels", type=int, default=50)
    parser.add_argument("--calibration-runs", type=int, default=3)
    parser.add_argument("--timing-tolerance", type=float, default=0.05)
    parser.add_argument("--timing-skip-frames", type=int, default=16)
    args = parser.parse_args()
    args.methods = list(dict.fromkeys(args.methods))
    if args.match_time and "ours" not in args.methods:
        parser.error("Time matching requires ours as the fixed target")
    if not 0 <= args.calibration_runs <= 3 or not 0 < args.timing_tolerance < 1:
        parser.error("Use 0-3 calibration runs and a timing tolerance between 0 and 1")
    if args.spp < 1 or args.grid_res < 1 or args.ellipse_samples < 1 or args.calibration_voxels < 1:
        parser.error("SPP, grid resolution, ellipse samples and calibration voxels must be positive")

    scene = load_scene_config(args.scene, gate_width=args.gate_width)
    setup = replace(SnlosSetup(), grid_res=args.grid_res, ellipse_samples=args.ellipse_samples,
                    origin=tuple(scene.light_position))
    testbed = create_testbed(scene)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    spps = calibrate(testbed, scene, setup, args, output) if args.match_time else {m: args.spp for m in args.methods}
    scan = scan_frames(setup, args.voxel_limit)
    summaries = []
    for method in args.methods:
        method_dir = output / method
        (method_dir / "frames").mkdir(parents=True, exist_ok=True)
        for stale in (method_dir / "frames").glob("voxel_*.npz"):
            stale.unlink()
        manifest = {"experiment": "application_1_snlos", "scene": asdict(scene), "snlos": setup.to_dict(),
                    "method": method, "label": METHOD_LABELS[method], "spp_per_frame": spps[method],
                    "sampling_method": "ellipsoidal", "ellipsoidal_mis": False,
                    "temporal_reuse": method != "pt", "scene_dynamic": method != "pt",
                    "temporal_history_length": args.temporal_history_length if method != "pt" else None,
                    "spatial_iterations": args.iterations if method != "pt" else 0,
                    "spatial_neighbors": args.neighbors if method != "pt" else 0,
                    "spatial_radius_pixels": args.radius if method != "pt" else None,
                    "shiftmap_method": {"pt": None, "naive": "no"}.get(method, scene.shiftmap_method),
                    "voxels": [voxel for voxel, _, _ in scan],
                    "saved_channel": "red (radiance / gate width, rows top to bottom)",
                    "status": "rendering"}
        save_json(method_dir / "run.json", manifest)
        rows = run_scan(testbed, scene, setup, method, spps[method], args, scan, output=method_dir)
        save_csv(method_dir / "frames.csv", rows)
        summary = {"method": method, "spp": spps[method], **summarize(rows)}
        summaries.append(summary)
        manifest.update(status="complete", timing_summary=summary)
        save_json(method_dir / "run.json", manifest)
        save_csv(output / "timing_summary.csv", summaries)
        print(f"{method}: {spps[method]} SPP, {summary['mean_frame_ms']:.3f} ms/frame -> {method_dir}", flush=True)


if __name__ == "__main__":
    main()
