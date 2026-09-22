#!/usr/bin/env bash
set -euo pipefail

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="${1:-$OUTPUT_PATH/exp1_offline_rendering_with_spatial_reuse_equal_time}"

run_scene() {
    local scene="$1"
    local seconds="$2"
    local gate_width="$3"
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_spatial_reuse_comparison.py" \
        --scene "$release_dir/scenes/exp1/$scene.json" \
        --seconds "$seconds" \
        --gate-width "$gate_width" \
        --spp-per-frame 32 --warmup-frames 50 \
        --neighbors 5 --iterations 3 \
        --reference-spp 262144 \
        --output "$output_dir/$scene"
    printf 'Saved errors: %s\n' "$output_dir/$scene/errors.csv"
}

# Scene, time budget (seconds), gate width (path-length units).
run_scene cornell_box 1.5 0.02
run_scene cornell_box_glass_bunny 2.7 0.05
run_scene cornell_box_dragon_specular 4.0 0.01
