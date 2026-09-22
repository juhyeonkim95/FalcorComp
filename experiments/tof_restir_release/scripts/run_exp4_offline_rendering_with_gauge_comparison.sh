#!/usr/bin/env bash
set -euo pipefail

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="${1:-$OUTPUT_PATH/exp4_offline_rendering_with_gauge_comparison}"

# Scene config name and gate width; shiftmapMethod comes from each scene JSON.
experiments=(
    "cornell_box 0.0100"
    "cornell_box_dragon_diffuse 0.0100"
)

for experiment in "${experiments[@]}"; do
    read -r scene gate_width <<< "$experiment"
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_gauge_comparison.py" \
        --scene "$release_dir/scenes/exp4/$scene.json" \
        --spp 1024 --gate-width "$gate_width" \
        --spp-per-frame 32 --warmup-frames 10 \
        --neighbors 5 --iterations 3 \
        --reference-spp 262144 \
        --output "$output_dir/$scene"
done
