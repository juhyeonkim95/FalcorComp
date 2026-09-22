"""Evaluate saved histograms and plot a selected pixel; never imports Falcor."""
import argparse
import json
from pathlib import Path
import sys

import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.histogram import METHODS, load_histogram
from common.io import save_csv
from common.metrics import pixel_mape


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pixel-x", type=int, default=192)
    parser.add_argument("--pixel-y", type=int, default=132)
    args = parser.parse_args()
    manifest = json.loads((args.output / "run.json").read_text())
    if manifest["status"] != "complete":
        raise ValueError("Rendering is incomplete")
    width, height = manifest["resolution"]
    x, y = args.pixel_x, args.pixel_y
    if not (0 <= x < width and 0 <= y < height):
        parser.error(f"Pixel must lie inside {width} x {height}; coordinates are zero-based")
    bins = manifest["bins"]
    reference = Path(manifest["reference"])
    reference_info = json.loads(reference.with_suffix(".json").read_text())
    if reference_info["signature"] != manifest["reference_signature"]:
        raise ValueError("The shared reference has different rendering settings")
    curves = {method: np.asarray(load_histogram(manifest["methods"][method]["file"],
                  manifest["resolution"], bins)[y, x], dtype=np.float64) for method in METHODS}
    curves["gt"] = np.asarray(load_histogram(reference, manifest["resolution"], bins)[y, x], dtype=np.float64)
    gt = curves["gt"]
    centers = manifest["time_min"] + (np.arange(bins) + .5) * manifest["bin_width"]
    destination = args.output / "evaluation"
    destination.mkdir(exist_ok=True)
    stem = f"pixel_{x}_{y}"
    save_csv(destination / f"{stem}_transient.csv", [
        {"bin": b, "path_length": centers[b], **{method: curve[b] for method, curve in curves.items()}}
        for b in range(bins)
    ])
    errors = []
    energy = float(np.mean(gt * gt))
    for method in METHODS:
        curve = curves[method]
        mse = float(np.mean((curve - gt) ** 2))
        mape = float(np.mean(pixel_mape(curve[:, None, None], gt[:, None, None]))) if gt.mean() > 0 else None
        row = {"method": method, "pixel_x": x, "pixel_y": y, "rmse": float(np.sqrt(mse)),
               "relative_mse": mse / energy if energy > 0 else None, "mape": mape}
        errors.append(row)
        print(row)
    save_csv(destination / f"{stem}_errors.csv", errors)
    fig, ax = plt.subplots(figsize=(8, 4.5))
    labels = {"pt": "PT", "kde": "PT + KDE (Epanechnikov)", "tri_approx": "Triangle approximation",
              "gt": f"GT ({manifest['reference_spp']} spp)"}
    lod = manifest["methods"]["tri_approx"].get("lod")
    if lod is not None:
        labels["tri_approx"] += f" (LOD {lod})"
    colors = {"pt": "tab:blue", "kde": "tab:orange", "tri_approx": "tab:green", "gt": "black"}
    for method in ("gt", *METHODS):
        ax.plot(centers, curves[method], label=labels[method], color=colors[method],
                linestyle="--" if method == "gt" else "-", linewidth=1.5)
    ax.set(xlabel="Path length (scene units)", ylabel="Transient radiance density (red channel)",
           title=f"Cornell box — pixel ({x}, {y})")
    ax.grid(alpha=.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(destination / f"{stem}_transient.png", dpi=180)
    fig.savefig(destination / f"{stem}_transient.svg")
    plt.close(fig)
    print(f"Saved pixel curves, errors, and plots to {destination}")


if __name__ == "__main__":
    main()
