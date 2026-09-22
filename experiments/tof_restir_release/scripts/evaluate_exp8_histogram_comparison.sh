#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

scene=cornell_box
pixel_x=192
pixel_y=132

"${PYTHON:-python}" "$release_dir/src/plots/plot_exp8_histogram_comparison.py" \
    "$OUTPUT_PATH/exp8_offline_histogram_comparison/$scene" \
    --pixel-x "$pixel_x" --pixel-y "$pixel_y"
