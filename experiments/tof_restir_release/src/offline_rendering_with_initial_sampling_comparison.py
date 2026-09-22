"""Compare PT, naive reuse, and ours with direct, ellipsoid, and ellipsoid MIS sampling."""

from offline_rendering_with_spatial_reuse_comparison import ROOT, main

SAMPLING_METHODS = {
    "direct": "direct",
    "ellipsoid": "ellipsoidal",
    "ellipsoid_mis": "ellipsoidal_direct_mis",
}
VARIANTS = {f"{renderer}_{sampling}": (renderer, {})
            for renderer in ("pt", "naive", "ours") for sampling in SAMPLING_METHODS}
INITIAL_SAMPLING = {f"{renderer}_{label}": method
                    for renderer in ("pt", "naive", "ours")
                    for label, method in SAMPLING_METHODS.items()}

if __name__ == "__main__":
    main(variants=VARIANTS, sampling_methods=INITIAL_SAMPLING, evaluate_errors=False,
         default_scene=ROOT / "scenes/exp5/cornell_box.json",
         experiment="offline_rendering_with_initial_sampling_comparison", description=__doc__)
