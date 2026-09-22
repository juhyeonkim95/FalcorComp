#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

# Edit scene names and zero-based grid frame indices here.
experiments=(
    # "cornell_box 1 2 4 16 32 64"
    # "veach_ajar 1 2 4 16 32 64"
    "classroom 5 15 30 50 70 90"
    "bedroom 5 15 30 50 70 90"
    "nlos_v2 5 15 30 50 70 90"
)
methods=(pt naive ours)
output_dir="$OUTPUT_PATH/exp7_online_rendering_equal_time"
for experiment in "${experiments[@]}"; do
    read -r -a fields <<< "$experiment"
    scene="${fields[0]}"
    frames=("${fields[@]:1}")
    "${PYTHON:-python}" "$release_dir/src/evaluation/evaluate_exp7_sequence.py" \
        "$output_dir/$scene" --methods "${methods[@]}"
    "${PYTHON:-python}" "$release_dir/src/plots/plot_exp7_sequence_grid.py" \
        "$output_dir/$scene" --frames "${frames[@]}"
done
