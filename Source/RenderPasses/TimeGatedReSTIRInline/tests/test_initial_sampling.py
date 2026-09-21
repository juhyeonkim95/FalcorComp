"""GPU regression checks for initial proposals and their spatial reuse.

Run from the repository root after building TimeGatedReSTIRInline:
    source build/GCC_11.3.0x86_64-linux-gnu/bin/setpath.sh
    python Source/RenderPasses/TimeGatedReSTIRInline/tests/test_initial_sampling.py

Requires the experiment's Cornell scene. This checks finite output, proposal
agreement, identity/local-only preservation, and actual neighbor reuse. The
brightness comparison is a Monte Carlo regression check, not a proof of unbiasedness.
"""
from pathlib import Path

import falcor
import numpy as np

ROOT = Path(__file__).resolve().parents[4]
SCENE = ROOT / "experiments/scene/cornell-box/scene-v4-nolight.pbrt"
MODES = ("direct", "ellipsoidal", "ellipsoidal_direct_mis")


def render(testbed, mode, sampler="LightBVH", iterations=0, radius=8., threshold=.25,
           ellipse_threshold=.25, frames=1, laser=True, shift_method="local_tangent", gauge_mode="avg_grad"):
    graph = testbed.create_render_graph("initial_sampling_test")
    graph.create_pass("V", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("L", "LaserVBufferRT", {
        "samplePattern": "Center", "sampleCount": 1,
        "laserPosition": [0., 1.7, 6.8], "laserDirection": [0., 0., -1.],
        "laserPower": [170., 120., 40.], "laserAngle": 0.,
    })
    graph.create_pass("P", "TimeGatedReSTIRInline", {
        "samplingMethod": mode, "emissiveSampler": sampler,
        "samplesPerPixel": 32, "maxBounces": 6,
        "timeGateMode": "box", "timeGateWindow": .5,
        "timeMin": 17.337, "timeMax": 17.337, "timeBin": 1,
        "laserCollocated": False, "isLightSourceLaser": laser,
        "isSceneDynamic": False, "useTemporalReuse": False,
        "spatialReuseIteration": iterations, "spatialReuseNeighborCount": 5,
        "spatialReuseGatherRadius": radius,
        "specularRoughnessThreshold": threshold,
        "specularRoughnessThresholdEllipsoid": ellipse_threshold,
        "shiftmapMethod": shift_method, "gaugeMode": gauge_mode,
    })
    for source, target in [("V.vbuffer", "P.vbuffer"), ("V.viewW", "P.viewW"),
                           ("L.vbuffer", "P.laservbuffer"), ("L.viewW", "P.laserviewW")]:
        graph.add_edge(source, target)
    graph.mark_output("P.color")
    testbed.render_graph = graph
    total = 0.
    for _ in range(frames):
        testbed.frame()
        image = graph.get_output("P.color").to_numpy()[..., :3].copy()
        assert np.isfinite(image).all(), (mode, sampler, "non-finite output")
        assert np.all(image >= 0), (mode, sampler, "negative output")
        total = total + image
    result = total / frames
    assert result.max() > 0, (mode, sampler, "black output")
    return result


def main():
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(str(SCENE))
    testbed.resize_frame_buffer(65, 49)  # Also exercises partial thread groups.
    testbed.scene.camera.aspectRatio = 65 / 49
    testbed.scene.camera.apertureRadius = 0
    testbed.clock.pause()
    reference = render(testbed, "direct", frames=64)
    for sampler in ("Uniform", "LightBVH"):
        for mode in MODES:
            base = render(testbed, mode, sampler)
            identity = render(testbed, mode, sampler, iterations=3, radius=0.)
            np.testing.assert_allclose(identity, base, rtol=2e-4, atol=1e-6)
            reused = render(testbed, mode, sampler, iterations=3)
            assert not np.allclose(reused, base), (mode, sampler, "no neighbor reuse")
            local = render(testbed, mode, sampler, threshold=2.)
            local_reused = render(testbed, mode, sampler, iterations=3, threshold=2.)
            np.testing.assert_allclose(local_reused, local, rtol=2e-4, atol=1e-6)
            for iterations in (0, 3):
                mean = render(testbed, mode, sampler, iterations=iterations, frames=64).mean()
                relative_difference = abs(mean / reference.mean() - 1.)
                assert relative_difference < .06, (mode, sampler, iterations, relative_difference)
                print(mode, sampler, "reuse", iterations, "mean", mean, flush=True)
    # With the ellipse eligibility threshold above every roughness, pure ellipse
    # mode must reduce to the same direct walk, including its random streams.
    direct = render(testbed, "direct")
    disabled = render(testbed, "ellipsoidal", ellipse_threshold=2.)
    np.testing.assert_array_equal(disabled, direct)
    # Exercise the other light endpoint representation as well.
    for mode in MODES:
        render(testbed, mode, laser=False)
    print("Initial sampling and spatial reuse checks passed.", flush=True)


if __name__ == "__main__":
    main()
