"""Plot actual reuse successes / attempts across gate widths, from raw count exports."""

import argparse
import csv
import json
from pathlib import Path
import sys

import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.io import save_csv
from common.reuse_statistics import summarize_counts, summarize_distances


def plot(output):
    rows = []
    for path in sorted(output.glob("gate_*/statistics.csv")):
        manifest = json.loads((path.parent / "statistics_run.json").read_text())
        if manifest["status"] != "complete":
            raise ValueError(f"Incomplete statistics run: {path.parent}")
        with path.open() as stream:
            gate_rows = list(csv.DictReader(stream))
        if sorted(row["method"] for row in gate_rows) != ["naive_reuse", "ours"]:
            raise ValueError(f"Expected exactly naive_reuse and ours: {path}")
        for row in gate_rows:
            # Recompute from four-channel count arrays; never read PNG/radiance images.
            counts = np.load(path.parent / row["counts_file"], allow_pickle=False)
            summary = summarize_counts(counts)
            if row.get("mapping_distance_file"):
                summary.update(summarize_distances(
                    np.load(path.parent / row["mapping_distance_file"], allow_pickle=False), counts))
            rows.append({"method": row["method"], "gate_width": float(row["gate_width"]), **summary})
    if not rows:
        raise ValueError(f"No gate_*/statistics.csv in {output}")
    rows.sort(key=lambda row: (row["method"], row["gate_width"]))
    save_csv(output / "reuse_success_rates.csv", rows)
    fig, ax = plt.subplots(figsize=(6, 4))
    for method, label, color in (("naive_reuse", "Naive reuse", "tab:orange"), ("ours", "Ours", "tab:blue")):
        values = [row for row in rows if row["method"] == method]
        widths = [row["gate_width"] for row in values]
        if any(w <= 0 for w in widths) or len(set(widths)) != len(widths):
            raise ValueError("Gate widths must be positive and unique per method")
        rates = [np.nan if row["actual_success_rate"] is None else row["actual_success_rate"] for row in values]
        ax.plot(widths, rates, "o-", label=label, color=color)
    ax.set(xscale="log", ylim=(0, 1), xlabel="Time gate width", ylabel="Actual reuse success rate")
    ax.grid(True, which="both", alpha=.25)
    ax.legend()
    fig.tight_layout()
    for suffix in ("png", "svg"):
        fig.savefig(output / f"actual_reuse_success_rate.{suffix}", dpi=200)
    plt.close(fig)
    print(f"Saved reuse_success_rates.csv and actual_reuse_success_rate.png/svg in {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    plot(parser.parse_args().output.resolve())
