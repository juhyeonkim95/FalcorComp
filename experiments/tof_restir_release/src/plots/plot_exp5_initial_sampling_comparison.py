"""Plot exp5 errors against actual SPP and rendering time, without resampling curves."""

import argparse
import csv
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.metrics import evaluate_run

import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

COLORS = {"pt": "tab:blue", "naive": "tab:orange", "ours": "tab:green"}
STYLES = {
    "direct": ("-", "o", "direct"),
    "ellipsoidal": ("--", "s", "ellipsoid"),
    "ellipsoidal_direct_mis": (":", "^", "ellipsoid_mis"),
}
METRICS = {"rmse": "RMSE", "relative_mse": "Relative MSE", "mape": "MAPE (fraction)"}


def load_curves(run, sampling_methods=None):
    selected = set(STYLES if sampling_methods is None else sampling_methods)
    manifest = json.loads((run / "run.json").read_text())
    if manifest["status"] != "complete":
        raise ValueError(f"Run is incomplete: {run}")
    with (run / "errors.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    curves = {}
    for row in rows:
        key = (row["renderer"], row["sampling_method"])
        if key[0] not in COLORS or key[1] not in STYLES:
            raise ValueError(f"Unknown renderer/sampling combination: {key}")
        if key[1] not in selected:
            continue
        for field in ("spp", "elapsed_seconds", *METRICS):
            row[field] = float(row[field])
            if not math.isfinite(row[field]) or row[field] < 0:
                raise ValueError(f"Invalid {field} in {run}")
        if row["spp"] <= 0 or row["elapsed_seconds"] <= 0:
            raise ValueError("SPP and elapsed time must be positive")
        # Multiple time budgets can cross in one frame; plot that image only once.
        points = curves.setdefault(key, {})
        points[row["image"]] = row
    expected = {(renderer, sampling) for renderer in COLORS for sampling in selected}
    if set(curves) != expected:
        raise ValueError(f"Missing renderer/sampling combinations for the selected methods in {run}")
    return manifest, {key: list(points.values()) for key, points in curves.items()}


def plot(run, sampling_methods=None):
    manifest = json.loads((run / "run.json").read_text())
    if manifest["status"] != "complete":
        raise ValueError(f"Run is incomplete: {run}")
    # Always recompute: the GT may have been replaced since the last plot.
    errors = evaluate_run(run)
    print(f"\n{run.name}: errors against current reference.npy")
    print("method                         spp       seconds    RMSE          relative_MSE  MAPE")
    for row in errors:
        print(f"{row['method']:28s} {int(row['spp']):8d} {float(row['elapsed_seconds']):10.3f} "
              f"{row['rmse']:12.6g} {row['relative_mse']:12.6g} {row['mape']:.6g}")
    selected = list(STYLES if sampling_methods is None else sampling_methods)
    manifest, curves = load_curves(run, selected)
    output = run / "plots"
    output.mkdir(exist_ok=True)
    legend = [Line2D([], [], color=color, lw=2, label=renderer) for renderer, color in COLORS.items()]
    legend += [Line2D([], [], color="black", linestyle=style, marker=marker, label=label)
               for style, marker, label in (STYLES[method] for method in selected)]
    for metric, ylabel in METRICS.items():
        for axis, xlabel, suffix in (("spp", "Initial samples per pixel", "spp"),
                                     ("elapsed_seconds", "Rendering time (seconds)", "time")):
            fig, ax = plt.subplots(figsize=(7.5, 4.8), layout="constrained")
            for (renderer, sampling), points in curves.items():
                points = sorted(points, key=lambda row: row[axis])
                style, marker, _ = STYLES[sampling]
                ax.plot([p[axis] for p in points], [p[metric] for p in points],
                        color=COLORS[renderer], linestyle=style, marker=marker, markersize=4)
            ax.set(xlabel=xlabel, ylabel=ylabel, title=manifest["scene"]["name"], xscale="log")
            ax.set_yscale("log", nonpositive="mask")  # Exact zero errors have no finite log coordinate.
            ax.grid(True, which="both", alpha=.25)
            ax.legend(handles=legend, ncol=2)
            for extension in ("png", "svg"):
                fig.savefig(output / f"{metric}_vs_{suffix}.{extension}", dpi=180)
            plt.close(fig)
    print(f"Saved error plots against SPP and time to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", type=Path, nargs="+", help="Completed scene run directories")
    parser.add_argument("--sampling", nargs="+", choices=["direct", "ellipsoid", "ellipsoid_mis"],
                        help="Sampling methods to show; default: all")
    args = parser.parse_args()
    aliases = {values[2]: key for key, values in STYLES.items()}
    selected = list(dict.fromkeys(aliases[name] for name in args.sampling)) if args.sampling else None
    for run in args.runs:
        plot(run.resolve(), selected)
