"""Exp8: render histogram arrays only. Evaluation and plotting run separately."""
import argparse
from dataclasses import replace
import json
from pathlib import Path
from time import perf_counter

import numpy as np
from tqdm import trange

from common.config import load_scene_config
from common.histogram import METHODS, create_histogram_graph, histogram_to_hwb, load_histogram
from common.io import save_json
from common.paths import RELEASE_OUTPUT_PATH
from common.rendering import create_testbed


def render(testbed, scene, method, spp, bins, ratio, destination):
    graph = create_histogram_graph(testbed, scene, method, spp, bins, ratio)
    start = perf_counter()
    for _ in trange(1, desc=f"{method}: {spp} requested spp", unit="histogram"):
        testbed.frame()
        testbed.device.wait()
    elapsed = perf_counter() - start
    values = histogram_to_hwb(graph.get_output("Tracer.histogram").to_numpy(), scene.resolution, bins)
    destination.parent.mkdir(parents=True, exist_ok=True)
    np.save(destination, values)
    return {"file": str(destination.resolve()), "requested_spp": spp,
            "effective_path_spp": None if method == "tri_approx" else spp,
            "render_seconds_including_compilation": elapsed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tri-approx-lod", type=int, choices=range(5), default=None,
                        help="Cornell subdivision level 0–4, used only by triangle approximation")
    parser.add_argument("--bins", type=int, default=64)
    parser.add_argument("--spp", type=int, default=64)
    parser.add_argument("--reference-spp", type=int, default=1024)
    parser.add_argument("--initial-window-ratio", type=float, default=1.)
    args = parser.parse_args()
    if min(args.bins, args.spp, args.reference_spp) < 1 or not 0 < args.initial_window_ratio <= 1:
        parser.error("Bins/SPP must be positive and initial-window-ratio in (0, 1]")
    settings = json.loads(args.scene.read_text())
    width = (settings["gate_max"] - settings["gate_min"]) / args.bins
    scene = load_scene_config(args.scene, gate_width=width)
    if width <= 0 or scene.light_collocated:
        parser.error("This experiment requires a positive histogram range and a fixed explicit light")
    triangle_scene = scene
    if args.tri_approx_lod is not None:
        if scene.name != "cornell-box":
            parser.error("tri-approx-lod currently supports only cornell-box")
        scene_file = Path(__file__).resolve().parents[2] / "scene" / "cornell-box-subdivide" / f"scene-v4-{args.tri_approx_lod}.pbrt"
        if not scene_file.is_file():
            parser.error(f"Subdivision scene does not exist: {scene_file}")
        triangle_scene = replace(scene, scene_file=str(scene_file))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Never let an interrupted rerun appear complete to the evaluator.
    (output / "run.json").unlink(missing_ok=True)
    reference_dir = RELEASE_OUTPUT_PATH / "reference_histogram" / scene.name / (
        f"bins_{args.bins}_{scene.gate_min:.4f}_{scene.gate_max:.4f}")
    reference_dir.mkdir(parents=True, exist_ok=True)
    reference = reference_dir / "reference.npy"
    reference_info = reference_dir / "reference.json"
    signature = {"scene": scene.reference_signature(), "bins": args.bins,
                 "time_min": scene.gate_min, "time_max": scene.gate_max,
                 "channel": "red", "compute_direct": False, "format_version": 1}
    cached = None
    if reference.exists():
        # Existing GT is never overwritten, even if reference-spp was increased.
        # Reject incompatible data instead of silently replacing it.
        if not reference_info.is_file():
            raise ValueError(f"Existing GT metadata is missing: {reference_info}. GT was not overwritten.")
        info = json.loads(reference_info.read_text())
        if info.get("signature") != signature:
            raise ValueError(f"Existing GT settings differ: {reference}. GT was not overwritten.")
        load_histogram(reference, scene.resolution, args.bins)
        cached = info
        print(f"Reusing GT ({cached['requested_spp']} spp): {reference}")
    testbed = create_testbed(scene)
    records = {}
    for method in METHODS:
        if method == "tri_approx" and args.tri_approx_lod is not None:
            print(f"Triangle approximation: LOD {args.tri_approx_lod} ({triangle_scene.scene_file})")
            triangle_testbed = create_testbed(triangle_scene)
            records[method] = render(triangle_testbed, triangle_scene, method, args.spp, args.bins,
                                     args.initial_window_ratio, output / f"{method}.npy")
            records[method].update(lod=args.tri_approx_lod, scene_file=triangle_scene.scene_file)
            del triangle_testbed
        else:
            records[method] = render(testbed, scene, method, args.spp, args.bins,
                                     args.initial_window_ratio, output / f"{method}.npy")
    if cached is None:
        reference_info.unlink(missing_ok=True)
        cached = render(testbed, scene, "pt", args.reference_spp, args.bins, 1., reference)
        cached["signature"] = signature
        save_json(reference_info, cached)
    save_json(output / "run.json", {
        "status": "complete", "resolution": scene.resolution, "bins": args.bins,
        "time_min": scene.gate_min, "time_max": scene.gate_max, "bin_width": width,
        "layout": "H,W,B", "channel": "red", "quantity": "radiance density per unit path length",
        "kde_kernel": "epanechnikov", "initial_window_ratio": args.initial_window_ratio,
        "reference": str(reference), "reference_spp": cached["requested_spp"],
        "reference_signature": signature, "methods": records,
        "note": "Triangle approximation ignores SPP and traces one intermediate triangle; PT includes up to maxBounces. "
                "GT and PT share initial RNG samples. Times include compilation and are not benchmark timings.",
    })
    print(f"Saved histograms to {output}. Run the separate evaluation script to plot.")


if __name__ == "__main__":
    main()
