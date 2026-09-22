"""Recalculate errors and plot MAPE over gate multiplier, colored by rough-sample ratio."""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.metrics import evaluate_run
from common.io import save_csv

import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt


def plot(run):
    manifest = json.loads((run / "run.json").read_text())
    if manifest["status"] != "complete":
        raise ValueError(f"Run is incomplete: {run}")
    rows = evaluate_run(run)
    curves = {}
    print("gate multiplier  rough ratio  effective rough ratio  MAPE")
    for row in rows:
        options = manifest["shrink_options"][row["method"]]
        multiplier = options["timeGateWindowRough"] / manifest["scene"]["gate_width"]
        ratio = options["roughTimeGateSampleRatio"]
        spp_per_frame = int(row["spp_per_frame"])
        effective = min(int(spp_per_frame * ratio), spp_per_frame) / spp_per_frame
        row.update(gate_multiplier=multiplier, rough_sample_ratio=ratio, effective_rough_sample_ratio=effective)
        curves.setdefault(ratio, []).append((multiplier, row["mape"]))
        print(f"{multiplier:15g} {ratio:12.2f} {effective:22.5f} {row['mape']:.6g}")
    save_csv(run / "errors.csv", rows)
    fig, ax = plt.subplots(figsize=(7.5, 4.8), layout="constrained")
    for ratio, points in sorted(curves.items()):
        points.sort()
        ax.plot([p[0] for p in points], [p[1] for p in points], marker="o", label=f"{ratio:.2f}")
    multipliers = sorted({p[0] for points in curves.values() for p in points})
    ax.set(xscale="log", xlabel="Wide / original gate width", ylabel="MAPE (fraction)",
           title=manifest["scene"]["name"])
    ax.set_xticks(multipliers, [f"{v:g}" for v in multipliers])
    ax.grid(True, which="both", alpha=.25)
    ax.legend(title="Requested rough-sample ratio")
    output = run / "plots"
    output.mkdir(exist_ok=True)
    for extension in ("png", "svg"):
        fig.savefig(output / f"mape_vs_gate_multiplier.{extension}", dpi=180)
    plt.close(fig)
    print(f"Saved errors.csv and plots to {run}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    plot(parser.parse_args().run.resolve())
