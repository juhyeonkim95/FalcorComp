#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

# Scanning NLOS reconstruction from run_application_1_snlos_rendering.sh outputs:
# score maps, final reconstruction images, and videos of the voxels revealed in scan order.
objects=(
    teapot_pressed
    dragon_pressed
    # bunny_pressed
)
output_dir="$OUTPUT_PATH/application_1_snlos"
fps=60

for object in "${objects[@]}"; do
    "${PYTHON:-python}" "$release_dir/src/application_1_snlos_reconstruction.py" \
        --run "$output_dir/$object" --fps "$fps"
done
