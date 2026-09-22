#!/usr/bin/env bash
set -euo pipefail

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="${1:-$OUTPUT_PATH/exp2_offline_rendering_with_spatial_reuse_gate_width_sweep}"

# Experiment 2: offline PT, naive, and ours at 3 seconds per gate width.
for gate_width in 0.0050 0.0100 0.0200 0.0500 0.1000 0.2000 0.5000 1.0000; do
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_spatial_reuse_comparison.py" \
        --scene "$release_dir/scenes/exp2/cornell_box_dragon_diffuse.json" \
        --seconds 3.0 --gate-width "$gate_width" \
        --spp-per-frame 32 --warmup-frames 50 \
        --neighbors 5 --iterations 3 \
        --reference-spp 262144 \
        --output "$output_dir/gate_$gate_width"
    printf 'Saved errors: %s\n' "$output_dir/gate_$gate_width/errors.csv"
done

"${PYTHON:-python}" "$release_dir/src/plots/plot_exp2_offline_rendering_with_spatial_reuse_gate_width_sweep.py" "$output_dir"
