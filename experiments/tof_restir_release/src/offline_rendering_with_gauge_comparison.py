"""Offline gauge comparison of fixed horizontal/vertical gauge axes and avg_grad."""

from offline_rendering_with_spatial_reuse_comparison import ROOT, main

# Axes are gaugeAxis values in the local surface chart, not screen-space axes.
VARIANTS = {
    "horizontal": ("ours", {"gauge_mode": "constant", "gauge_axis": (1.0, 0.0)}),
    "vertical": ("ours", {"gauge_mode": "constant", "gauge_axis": (0.0, 1.0)}),
    "avg_grad": ("ours", {"gauge_mode": "avg_grad"}),
}

if __name__ == "__main__":
    main(
        variants=VARIANTS,
        statistics=True,
        default_scene=ROOT / "scenes/exp4/cornell_box.json",
        experiment="offline_rendering_with_gauge_comparison",
        description=__doc__,
    )
