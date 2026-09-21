"""Plot Experiment 2 errors for linear NPY and display RGB PNG images."""

import argparse
import csv
import json
import math
from pathlib import Path
import sys

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.io import load_rgb, save_csv
from common.metrics import measure_error


METHODS = {"pt": "tab:blue", "naive": "tab:orange", "ours": "tab:green"}


def load_image(path, domain):
    if domain == "npy":
        return load_rgb(path)
    with Image.open(path.with_suffix(".png")) as image:
        return np.asarray(image.convert("RGB"), dtype=np.float64) / 255.0


def load_errors(directory, domain="npy"):
    points = []
    seconds = None
    for run in directory.glob("gate_*"):
        if not run.is_dir():
            continue
        if not (run / "run.json").is_file():
            continue  # A gate may contain imported GT before its comparison is rendered.
        manifest = json.loads((run / "run.json").read_text())
        width = float(manifest["scene"]["gate_width"])
        if manifest["status"] != "complete" or not math.isfinite(width) or width <= 0:
            raise ValueError(f"Invalid or incomplete run: {run}")
        with (run / "checkpoints.csv").open(newline="") as stream:
            rows = list(csv.DictReader(stream))
        if len(rows) != len(METHODS) or {r["method"] for r in rows} != set(METHODS):
            raise ValueError(f"Expected one checkpoint per method: {run}")
        reference = load_image(run / "reference.npy", domain)
        for row in rows:
            row.update(measure_error(load_image(run / row["image"], domain), reference))
            budget = float(row["requested_budget"])
            if row["budget_mode"] != "seconds" or not math.isfinite(budget) or budget <= 0:
                raise ValueError(f"Expected a positive time budget: {run}")
            if seconds is not None and budget != seconds:
                raise ValueError("All gates and methods must use the same time budget")
            seconds = budget
            for metric in ("rmse", "relative_mse", "mape"):
                row[metric] = float(row[metric])
                if not math.isfinite(row[metric]) or row[metric] < 0:
                    raise ValueError(f"Invalid {metric}: {run}")
        points.append((width, {r["method"]: r for r in rows}))
    if not points:
        raise ValueError(f"No gate runs found in {directory}")
    points.sort(key=lambda point: point[0])
    if len({width for width, _ in points}) != len(points):
        raise ValueError("Duplicate gate widths")
    return points, seconds


def plot_errors(directory, domain="npy"):
    points, seconds = load_errors(directory, domain)
    save_csv(directory / f"errors_{domain}.csv", [
        {"gate_width": width, "domain": domain, **row}
        for width, rows in points for row in rows.values()
    ])
    domain_label = "Linear RGB (NPY)" if domain == "npy" else "Display RGB (PNG)"
    widths = [width for width, _ in points]
    for metric, label in (("rmse", "RMSE"), ("relative_mse", "Relative MSE"), ("mape", "MAPE (fraction)")):
        fig, ax = plt.subplots(figsize=(6.4, 4.2), layout="constrained")
        for method, color in METHODS.items():
            ax.plot(widths, [rows[method][metric] for _, rows in points],
                    color=color, marker="o", label=method)
        ax.set_xscale("log")
        ax.set_yscale("log", nonpositive="mask")
        ax.set_xticks(widths, [f"{width:g}" for width in widths])
        ax.minorticks_off()
        ax.set(xlabel="Time gate width (path-length units)", ylabel=label,
               title=f"Experiment 2: {seconds:g} s per method — {domain_label}")
        ax.grid(True, alpha=0.25)
        ax.legend()
        # Preserve existing linear plot names; PNG-domain plots have a suffix.
        suffix = "" if domain == "npy" else "_png"
        output = directory / f"{metric}_vs_gate_width{suffix}.png"
        fig.savefig(output, dpi=200, backend="agg")
        plt.close(fig)
        print(f"Saved plot: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Experiment 2 output directory containing gate_* runs")
    args = parser.parse_args()
    for domain in ("npy", "png"):
        plot_errors(args.directory, domain)


if __name__ == "__main__":
    main()
