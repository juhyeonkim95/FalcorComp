"""GPU regression checks for histogram variants, reset, and a missed laser.

Build this pass and GBuffer, source bin/setpath.sh, then run this file.
These small Cornell checks do not establish estimator unbiasedness.
"""
from pathlib import Path

import falcor
import numpy as np

ROOT = Path(__file__).resolve().parents[4]


def create_graph(testbed, method, single_channel, kde, laser, filter_mode="box", accumulate=False):
    graph = testbed.create_render_graph("histogram_test")
    graph.create_pass("V", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("L", "LaserVBufferRT", {
        "laserPosition": [0., 1.7, 6.8], "laserDirection": [0., 0., -1.],
        "laserPower": [170., 120., 40.], "laserAngle": 0., "isLightSourceLaser": laser,
    })
    graph.create_pass("P", "TransientHistogramPathTracerInline", {
        "samplingMethod": method, "useSingleChannel": single_channel,
        "useKernelDensityEstimation": kde, "accumulate": accumulate,
        "timeGateMode": filter_mode, "timeMin": 0., "timeMax": 40., "timeBin": 16,
        "samplesPerPixel": 4, "maxBounces": 3,
    })
    for source, target in [("V.vbuffer", "P.vbuffer"), ("V.viewW", "P.viewW"),
                           ("L.vbuffer", "P.laservbuffer"), ("L.viewW", "P.laserviewW")]:
        graph.add_edge(source, target)
    graph.mark_output("P.histogram")
    graph.mark_output("P.color")
    testbed.render_graph = graph
    return graph


def main():
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(str(ROOT / "experiments/scene/cornell-box/scene-v4-nolight.pbrt"))
    testbed.resize_frame_buffer(17, 13)  # Exercise partial thread groups.
    testbed.scene.camera.aspectRatio = 17 / 13
    variants = [
        ("direct", True, False, True, "box"),
        ("direct", False, False, False, "tent"),
        ("direct", True, True, True, "box"),
        ("direct", False, True, False, "gaussian"),
        ("direct", True, True, True, "perlin"),
        ("tri_approx", True, False, True, "box"),
        ("tri_approx", False, False, False, "box"),
    ]
    for method, mono, kde, laser, filter_mode in variants:
        graph = create_graph(testbed, method, mono, kde, laser, filter_mode)
        testbed.frame()
        histogram = graph.get_output("P.histogram").to_numpy().copy()
        color = graph.get_output("P.color").to_numpy().copy()
        values = histogram if mono else histogram[..., :3]
        assert histogram.shape[:3] == (16, 13, 17)  # Falcor readback order: B,H,W.
        assert np.isfinite(histogram).all() and np.isfinite(color).all()
        assert np.all(values >= 0) and values.max() > 0
        if method == "tri_approx" and mono:
            # Deterministic: every frame writes the same per-frame histogram (no accumulation).
            testbed.frame()
            np.testing.assert_allclose(graph.get_output("P.histogram").to_numpy(), histogram,
                                       rtol=1e-4, atol=1e-6)
            # With accumulate, frames add up in place until reset_histogram().
            graph = create_graph(testbed, method, mono, kde, laser, filter_mode, accumulate=True)
            testbed.frame()
            testbed.frame()
            np.testing.assert_allclose(graph.get_output("P.histogram").to_numpy(), 2 * histogram,
                                       rtol=1e-4, atol=1e-6)
            graph.get_pass("P").reset_histogram()
            testbed.frame()
            np.testing.assert_allclose(graph.get_output("P.histogram").to_numpy(), histogram,
                                       rtol=1e-4, atol=1e-6)
        if method == "direct" and mono and not kde:
            graph.get_pass("L").update_laser_info([0., 1.7, 6.8], [0., 0., 1.])
            testbed.frame()
            assert not np.any(graph.get_output("P.histogram").to_numpy())
            assert not np.any(graph.get_output("P.color").to_numpy()[..., :3])
        print(f"Passed {method}, scalar={mono}, KDE={kde}, laser={laser}, filter={filter_mode}")

    testbed.resize_frame_buffer(19, 11)
    testbed.scene.camera.aspectRatio = 19 / 11
    testbed.frame()
    resized = graph.get_output("P.histogram").to_numpy().copy()
    assert resized.shape[:3] == (16, 11, 19) and np.isfinite(resized).all()
    testbed.frame()
    np.testing.assert_allclose(graph.get_output("P.histogram").to_numpy(), resized, rtol=1e-4, atol=1e-6)
    print("Passed histogram reallocation after resize")


if __name__ == "__main__":
    main()
