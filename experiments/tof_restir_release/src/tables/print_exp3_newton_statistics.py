"""Print and save scene-level Newton/reuse statistics from completed raw-counter runs."""

import argparse
import csv
import json
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.io import save_csv
from common.reuse_statistics import summarize_counts, summarize_distances

NOTE = ("Rates are fractions. Iteration averages use eligible reuse attempts, including failures. Distance means use pre-visibility mapping successes.\n"
        "Newton success* uses the pre-visibility mapping-success counter: identity shortcuts count as success with zero steps.\n"
        "Actual success also requires geometry, material, time-gate and visibility checks; it is not reservoir selection.\n"
        "These counters cannot isolate Newton-only attempts/successes from identity shortcuts. N/A means no attempts (or no Newton method).")


def collect_rows(runs):
    rows = []
    for run in runs:
        manifest = json.loads((run / "statistics_run.json").read_text())
        if manifest["status"] != "complete":
            raise ValueError(f"Incomplete run: {run}")
        with (run / "statistics.csv").open() as stream:
            records = list(csv.DictReader(stream))
        for record in records:
            raw_counts = np.load(run / record["counts_file"], allow_pickle=False)
            counts = summarize_counts(raw_counts)
            distances = summarize_distances(np.load(run / record["mapping_distance_file"], allow_pickle=False), raw_counts) if record.get("mapping_distance_file") else {"mean_xi_distance": None, "mean_world_distance": None}
            attempts = counts["attempt_count"]
            uses_newton = record["shiftmap_method"] != "no"
            rows.append({
                "scene": manifest["scene"]["name"], "method": record["method"],
                "shiftmap_method": record["shiftmap_method"], "gate_width": float(record["gate_width"]),
                "frames": int(record["frames"]), "spp": int(record["spp"]),
                "avg_newton_iterations_per_reuse_attempt": counts["newton_iteration_sum"] / attempts if attempts else None,
                "newton_mapping_success_rate": counts["mapping_success_count"] / attempts if attempts and uses_newton else None,
                **counts, **distances,
            })
    if not rows:
        raise ValueError("No statistics rows")
    return rows


def format_table(rows):
    headers = ("Scene", "Method", "Shift map", "Gate width", "Avg # iter", "Newton success*", "Actual success", "Mean xi distance", "Mean world distance")
    def value(number):
        return "N/A" if number is None else f"{number:.6f}"
    cells = [headers]
    for row in rows:
        cells.append((row["scene"], row["method"], row["shiftmap_method"], f"{row['gate_width']:.4f}",
                      value(row["avg_newton_iterations_per_reuse_attempt"]),
                      value(row["newton_mapping_success_rate"]), value(row["actual_success_rate"]),
                      value(row["mean_xi_distance"]), value(row["mean_world_distance"])))
    widths = [max(len(row[i]) for row in cells) for i in range(len(headers))]
    lines = [" | ".join(cell.ljust(width) for cell, width in zip(row, widths)) for row in cells]
    lines.insert(1, "-+-".join("-" * width for width in widths))
    return "\n".join(lines) + "\n\n" + NOTE + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", type=Path, nargs="+", help="Completed scene run directories")
    parser.add_argument("--output", type=Path, required=True, help="Directory for table.csv and table.txt")
    args = parser.parse_args()
    rows = collect_rows(args.runs)
    table = format_table(rows)
    args.output.mkdir(parents=True, exist_ok=True)
    save_csv(args.output / "table.csv", rows)
    (args.output / "table.txt").write_text(table)
    print(table, end="")


if __name__ == "__main__":
    main()
