"""Sweep wide-gate multipliers and rough-sample ratios using initial sampling only."""

import argparse
import math
import sys

from offline_rendering_with_spatial_reuse_comparison import ROOT, main


def build_sweep(gate_width, multipliers, ratios):
    if not math.isfinite(gate_width) or gate_width <= 0:
        raise ValueError("Gate width must be positive")
    if any(not math.isfinite(v) or v <= 1 for v in multipliers):
        raise ValueError("Gate multipliers must exceed one")
    if any(not math.isfinite(v) or not 0 <= v <= 1 for v in ratios):
        raise ValueError("Rough-sample ratios must be in [0, 1]")
    variants, options = {}, {}
    for multiplier in multipliers:
        for ratio in ratios:
            label = f"gate_{multiplier:g}_rough_{ratio:g}"
            variants[label] = ("ours", {"iterations": 0})
            options[label] = {
                "timeGateWindowRough": gate_width * multiplier,
                "roughTimeGateSampleRatio": ratio,
            }
    return variants, options


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--gate-width", type=float, required=True)
    parser.add_argument("--gate-multipliers", nargs="+", type=float, required=True)
    parser.add_argument("--rough-sample-ratios", nargs="+", type=float, required=True)
    sweep, remaining = parser.parse_known_args()
    variants, options = build_sweep(sweep.gate_width, sweep.gate_multipliers, sweep.rough_sample_ratios)
    sys.argv = [sys.argv[0], *remaining, "--gate-width", str(sweep.gate_width)]
    main(variants=variants, shrink_options=options, evaluate_errors=False,
         default_scene=ROOT / "scenes/exp6/cornell_box_dragon_diffuse.json",
         experiment="offline_rendering_with_shrink_mapping", description=__doc__)
