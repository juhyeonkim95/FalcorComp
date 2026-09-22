#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

# Edit experiment settings here.
# Scene config name and original gate width. Comment out scenes to skip them.
experiments=(
    # "cornell_box_dragon_diffuse 0.01"
    "staircase 0.01"
    "bedroom 0.01"
)
frames=32
spp_per_frame=32
reference_spp=1048576
gate_multipliers=(2 5 10 20 50 100 200 500)
rough_sample_ratios=(0.0 0.25 0.50 0.75 1.00)
output_dir="$OUTPUT_PATH/exp6_offline_rendering_with_shrink_mapping"

for experiment in "${experiments[@]}"; do
    read -r scene gate_width <<< "$experiment"
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_shrink_mapping.py" \
        --scene "$release_dir/scenes/exp6/$scene.json" --output "$output_dir/$scene" \
        --gate-width "$gate_width" --gate-multipliers "${gate_multipliers[@]}" \
        --rough-sample-ratios "${rough_sample_ratios[@]}" \
        --spp "$((frames * spp_per_frame))" --spp-per-frame "$spp_per_frame" \
        --warmup-frames 0 --iterations 0 --reference-spp "$reference_spp"
done
