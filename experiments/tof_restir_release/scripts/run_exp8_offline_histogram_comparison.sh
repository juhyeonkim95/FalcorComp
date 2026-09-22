#!/usr/bin/env bash
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$release_dir/output_paths.sh"

scene=cornell_box
bins=64
spp=2048
reference_spp=65536
initial_window_ratio=1.0
tri_approx_lod=4  # 0–4: scene-v4-<level>.pbrt; PT, KDE, and GT use the base scene.
# tri_approx currently ignores samplesPerPixel and evaluates each triangle once.

"${PYTHON:-python}" "$release_dir/src/offline_rendering_histogram_comparison.py" \
    --scene "$release_dir/scenes/exp8/$scene.json" \
    --output "$OUTPUT_PATH/exp8_offline_histogram_comparison/$scene" \
    --bins "$bins" --spp "$spp" --reference-spp "$reference_spp" \
    --initial-window-ratio "$initial_window_ratio" \
    --tri-approx-lod "$tri_approx_lod"
