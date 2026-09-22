#!/usr/bin/env bash
set -euo pipefail

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="${1:-$OUTPUT_PATH/exp2_offline_rendering_with_spatial_reuse_statistics}"

rm -f -- "$output_dir/reuse_success_rates.csv" "$output_dir/actual_reuse_success_rate.png" "$output_dir/actual_reuse_success_rate.svg"

# RGB plus separate Newton counters and mapping distances: naive reuse vs ours.
for gate_width in 0.0050 0.0100 0.0200 0.0500 0.1000 0.2000 0.5000 1.0000; do
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_spatial_reuse_statistics.py" \
        --scene "$release_dir/scenes/exp2/cornell_box_dragon_diffuse.json" \
        --frames 4 --gate-width "$gate_width" \
        --spp-per-frame 32 \
        --neighbors 5 --iterations 1 \
        --output "$output_dir/gate_$gate_width"
done

"${PYTHON:-python}" "$release_dir/src/plots/plot_exp2_spatial_reuse_statistics.py" "$output_dir"
