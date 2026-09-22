#!/usr/bin/env bash
set -euo pipefail

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
# Runs are separated automatically by budget mode.
output_dir="$OUTPUT_PATH/exp5_offline_rendering_with_initial_sampling_comparison"

run_scene() {
    local scene="$1" gate_width="$2" mode="$3"
    shift 3
    local budgets=("$@")
    case "$mode" in
        frames)
            # 32 initial samples per frame. Convert frame checkpoints to exact SPP.
            budgets=()
            for frames in "$@"; do budgets+=("$((frames * 32))"); done
            mode=spp ;;
        spp|seconds) ;;
        *) printf 'Unknown budget mode: %s\n' "$mode" >&2; return 1 ;;
    esac
    local budget_dir=equal_spp
    if [[ "$mode" == seconds ]]; then
        budget_dir=equal_time
    fi
    local run_dir="$output_dir/$budget_dir/$scene"
    "${PYTHON:-python}" "$release_dir/src/offline_rendering_with_initial_sampling_comparison.py" \
        --scene "$release_dir/scenes/exp5/$scene.json" --gate-width "$gate_width" \
        "--$mode" "${budgets[@]}" --spp-per-frame 32 --warmup-frames 50 \
        --neighbors 5 --iterations 3 --reference-spp 1048576 \
        --output "$run_dir"
}

# Scene, gate width, budget mode (frames/spp/seconds), checkpoints.
# run_scene cornell_box 0.01 frames 1 2 4 8 16 32
# run_scene veach_ajar 0.01 frames 1 2 4 8 16 32
# run_scene kitchen 0.01 frames 1 2 4 8 16 32
# run_scene bistro 0.05 frames 4 8 16 32 64 128
# For time budgets, replace a scene's line, e.g.:
run_scene cornell_box 0.01 seconds 1 2 4 8
run_scene veach_ajar 0.01 seconds 1 2 4 8
run_scene kitchen 0.01 seconds 2 4 8 16
