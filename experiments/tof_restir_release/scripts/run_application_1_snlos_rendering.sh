#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

# Scanning NLOS: PT / naive reuse / ours at equal time, then result plots and videos.
# Enable hidden objects here; scene configs are in scenes/application_1/<object>.json.
objects=(
    teapot_pressed
    dragon_pressed
    # bunny_pressed
)
output_dir="$OUTPUT_PATH/application_1_snlos"

# Ours renders at a fixed SPP with temporal + spatial reuse; PT and naive SPP are calibrated
# so their mean frame time matches ours (exp7 procedure, measured on the first voxels of the scan).
# Initial samples use ellipsoidal connection without MIS. The prototype settings are kept:
# 25x25 voxels, 16 laser positions per voxel, gate width 0.01, 2 bounces, M cap 5.
methods=(pt naive ours)
gate_width=0.01
spp=32
temporal_history_length=5
iterations=1
neighbors=3
radius=5
calibration_voxels=50
calibration_runs=3
timing_tolerance=0.05
timing_skip_frames=16
display_sample=6
fps=60

for object in "${objects[@]}"; do
    "${PYTHON:-python}" "$release_dir/src/application_1_snlos_rendering.py" \
        --scene "$release_dir/scenes/application_1/$object.json" --output "$output_dir/$object" \
        --methods "${methods[@]}" --gate-width "$gate_width" --spp "$spp" \
        --temporal-history-length "$temporal_history_length" \
        --iterations "$iterations" --neighbors "$neighbors" --radius "$radius" \
        --match-time --calibration-voxels "$calibration_voxels" --calibration-runs "$calibration_runs" \
        --timing-tolerance "$timing_tolerance" --timing-skip-frames "$timing_skip_frames"
    "${PYTHON:-python}" "$release_dir/src/plots/plot_application_1_snlos_rendering.py" \
        --run "$output_dir/$object" --display-sample "$display_sample" --fps "$fps"
done
