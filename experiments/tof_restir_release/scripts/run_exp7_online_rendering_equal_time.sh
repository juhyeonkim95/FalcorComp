#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

# Enable scenes here. Edit each scene's settings in the case blocks below.
# Gate, camera/light motion, and resolution remain in scenes/exp7/<scene>.json.
scenes=(
    # cornell_box
    # veach_ajar
    classroom
    bedroom
    nlos_v2
)
output_dir="$OUTPUT_PATH/exp7_online_rendering_equal_time"

# SPP is fixed for ours and used as the starting SPP for PT and naive.
# Incoming history M cap = temporal_history_length * each method's SPP.
# timing_skip_frames excludes initial frames from timing, not image export.
for scene in "${scenes[@]}"; do
    case "$scene" in
        cornell_box)
            methods=(pt naive ours)
            gate_width=0.01
            frames=100
            spp=32
            temporal_history_length=10
            iterations=1
            neighbors=3
            reference_spp=32768
            fps=30
            calibration_runs=3
            timing_tolerance=0.05
            timing_skip_frames=10
            ;;
        veach_ajar)
            methods=(pt naive ours)
            gate_width=0.01
            frames=100
            spp=32
            temporal_history_length=10
            iterations=1
            neighbors=3
            reference_spp=32768
            fps=30
            calibration_runs=3
            timing_tolerance=0.05
            timing_skip_frames=10
            ;;
        classroom)
            methods=(pt naive ours)
            gate_width=0.05
            frames=100
            spp=64
            temporal_history_length=20
            iterations=1
            neighbors=3
            reference_spp=32768
            fps=30
            calibration_runs=3
            timing_tolerance=0.05
            timing_skip_frames=10
            ;;
        bedroom)
            methods=(pt naive ours)
            gate_width=0.05
            frames=100
            spp=32
            temporal_history_length=20
            iterations=1
            neighbors=3
            reference_spp=1024
            fps=30
            calibration_runs=3
            timing_tolerance=0.05
            timing_skip_frames=10
            ;;
        nlos_v2)
            methods=(pt naive ours)
            gate_width=0.02
            frames=100
            spp=32
            temporal_history_length=20
            iterations=1
            neighbors=3
            reference_spp=1024
            fps=30
            calibration_runs=3
            timing_tolerance=0.05
            timing_skip_frames=10
            ;;
        *)
            echo "No exp7 settings defined for scene: $scene" >&2
            exit 1
            ;;
    esac

    "${PYTHON:-python}" "$release_dir/src/online_rendering_sequence.py" \
        --scene "$release_dir/scenes/exp7/$scene.json" --output "$output_dir/$scene" \
        --match-time --calibration-runs "$calibration_runs" --timing-tolerance "$timing_tolerance" \
        --methods "${methods[@]}" --gate-width "$gate_width" \
        --frames "$frames" --spp "$spp" --reference-spp "$reference_spp" --fps "$fps" \
        --iterations "$iterations" --neighbors "$neighbors" \
        --temporal-history-length "$temporal_history_length" --timing-skip-frames "$timing_skip_frames"
done
