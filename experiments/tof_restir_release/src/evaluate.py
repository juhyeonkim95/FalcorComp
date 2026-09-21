"""Recompute a saved experiment's errors.csv without Falcor or a GPU."""

import argparse
from pathlib import Path

from common.metrics import evaluate_run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path, help="Directory containing run.json, checkpoints.csv, and reference.npy")
    args = parser.parse_args()
    rows = evaluate_run(args.run_directory)
    print(f"Exported {len(rows)} error rows to {args.run_directory / 'errors.csv'}")


if __name__ == "__main__":
    main()
