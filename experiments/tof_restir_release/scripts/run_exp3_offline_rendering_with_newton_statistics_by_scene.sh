#!/usr/bin/env bash
set -euo pipefail

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="${1:-$OUTPUT_PATH/exp3_offline_rendering_with_newton_statistics_by_scene}"

# Add scene configs in scenes/exp3/, then add "scene_config_name gate_width" here.
experiments=(
    "cornell_box 0.0100"
    "cornell_box_dragon_diffuse 0.0100"
    "veach_ajar 0.0100"
    "kitchen 0.0100"
    "bedroom 0.0100"
    "staircase 0.0100"
)
run_dirs=()
rm -f -- "$output_dir/table.csv" "$output_dir/table.txt"
for experiment in "${experiments[@]}"; do
    read -r scene gate_width <<< "$experiment"
    run_dir="$output_dir/$scene"
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_spatial_reuse_statistics.py" \
        --scene "$release_dir/scenes/exp3/$scene.json" --methods ours \
        --frames 32 --gate-width "$gate_width" \
        --spp-per-frame 32 \
        --neighbors 5 --iterations 1 \
        --output "$run_dir"
    run_dirs+=("$run_dir")
done

"${PYTHON:-python}" "$release_dir/src/tables/print_exp3_newton_statistics.py" \
    "${run_dirs[@]}" --output "$output_dir"
