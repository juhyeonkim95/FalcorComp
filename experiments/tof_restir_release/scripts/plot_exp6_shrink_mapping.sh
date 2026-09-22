#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="$OUTPUT_PATH/exp6_offline_rendering_with_shrink_mapping"

# Plot only the selected exp6 scenes.
scenes=(cornell_box_dragon_diffuse staircase bedroom)
for scene in "${scenes[@]}"; do
    run_dir="$output_dir/$scene"
    if [[ ! -f "$run_dir/run.json" ]]; then
        printf 'Skipping %s: no rendered run yet.\n' "$scene"
        continue
    fi
    "${PYTHON:-python}" "$release_dir/src/plots/plot_exp6_shrink_mapping.py" "$run_dir"
done
