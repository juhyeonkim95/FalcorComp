"""GPU checks for per-bin initial RIS; run after building and sourcing bin/setpath.sh."""
from pathlib import Path

import falcor
import numpy as np

ROOT = Path(__file__).resolve().parents[4]


def render(testbed, *, threshold=0.25, single=True, laser=True, direct=False, mode="box"):
    graph = testbed.create_render_graph("histogram_initial_sampling")
    graph.create_pass("V", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("L", "LaserVBufferRT", {
        "laserPosition": [0., 1.7, 6.8], "laserDirection": [0., 0., -1.],
        "laserPower": [170., 120., 40.], "laserAngle": 0.,
    })
    graph.create_pass("P", "TransientHistogramReSTIRInline", {
        "samplesPerPixel": 32, "maxBounces": 6, "computeDirect": direct,
        "timeMin": 0., "timeMax": 40., "timeBin": 8, "timeGateMode": mode,
        "useSingleChannel": single, "isLightSourceLaser": laser,
        "specularRoughnessThreshold": threshold, "spatialReuseIteration": 0,
    })
    for source, target in [("V.vbuffer", "P.vbuffer"), ("V.viewW", "P.viewW"),
                           ("L.vbuffer", "P.laservbuffer"), ("L.viewW", "P.laserviewW")]:
        graph.add_edge(source, target)
    graph.mark_output("P.histogram")
    graph.mark_output("P.color")
    testbed.render_graph = graph
    testbed.frame()
    histogram = graph.get_output("P.histogram").to_numpy().copy()
    color = graph.get_output("P.color").to_numpy().copy()
    assert np.isfinite(histogram).all() and histogram.max() > 0
    assert np.all(histogram >= 0)
    # Histogram is radiance density; color integrates all bins, each of width 5.
    integrated = histogram.sum(axis=0) * 5.
    if single:
        np.testing.assert_allclose(integrated.squeeze(), color[..., 0], rtol=2e-5, atol=1e-5)
    else:
        np.testing.assert_allclose(integrated[..., :3], color[..., :3], rtol=2e-5, atol=1e-5)
    return histogram


def main():
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(str(ROOT / "experiments/scene/cornell-box/scene-v4-nolight.pbrt"))
    testbed.resize_frame_buffer(17, 13)
    testbed.scene.camera.aspectRatio = 17 / 13
    # In scalar RIS, W*f equals the sum of candidate contributions exactly.
    # Changing which vertices are reconnectable must not change initial radiance.
    reconnectable = render(testbed)
    local_only = render(testbed, threshold=1.)
    np.testing.assert_allclose(reconnectable, local_only, rtol=2e-5, atol=1e-5)
    print("Passed reconnectable versus local-only scalar RIS", flush=True)
    render(testbed, single=False, direct=True)
    render(testbed, laser=False, direct=True)
    render(testbed, mode="tent")
    print("Passed RGB, point light, primary direct lighting, and overlapping gates", flush=True)


if __name__ == "__main__":
    main()
