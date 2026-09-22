#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"
output_dir="$OUTPUT_PATH/exp5_offline_rendering_with_initial_sampling_comparison"
# Edit plotting settings here; no command-line options needed.
budget_modes=(equal_spp equal_time)
# Choices: direct, ellipsoid, ellipsoid_mis. For MIS only, remove direct.
sampling_methods=(direct ellipsoid_mis)

run_dirs=()
for budget_mode in "${budget_modes[@]}"; do
    for checkpoints in "$output_dir/$budget_mode"/*/checkpoints.csv; do
        run_dirs+=("$(dirname -- "$checkpoints")")
    done
done
if (( ${#run_dirs[@]} == 0 )); then
    printf 'No checkpoints.csv found under %s; run the rendering script first.\n' "$output_dir" >&2
    exit 1
fi

"${PYTHON:-python}" "$release_dir/src/plots/plot_exp5_initial_sampling_comparison.py" "${run_dirs[@]}" \
    --sampling "${sampling_methods[@]}"
