"""GPU integration checks for static spatial surface operations (K=1).

Run after building TimeGatedReSTIRInline and sourcing bin/setpath.sh.
Checks finite output, exact self reuse, and nontrivial neighbor reuse, not unbiasedness.
"""
import falcor
import numpy as np
from test_initial_sampling import ROOT, render


def check(testbed, method, laser=True, gauge="avg_grad"):
    options = dict(shift_method=method, laser=laser, gauge_mode=gauge, frames=2)
    base = render(testbed, "direct", **options)
    identity = render(testbed, "direct", iterations=3, radius=0., **options)
    np.testing.assert_allclose(identity, base, rtol=2e-4, atol=1e-6)
    reused = render(testbed, "direct", iterations=3, **options)
    assert not np.allclose(reused, base), (method, laser, gauge, "no neighbor reuse")
    print(method, "laser" if laser else "point", gauge, "PASS", flush=True)
    return reused


def main():
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    for scene, methods in [
        ("cornell-box", ("no", "local_tangent", "barycentric", "ray_trace", "area_adaptive", "ray_trace_chart")),
        ("cornell-box-dragon-diffuse", ("ray_trace", "area_adaptive", "ray_trace_chart")),
    ]:
        testbed.load_scene(str(ROOT / "experiments/scene" / scene / "scene-v4-nolight.pbrt"))
        testbed.resize_frame_buffer(33, 25)
        testbed.scene.camera.aspectRatio = 33 / 25
        testbed.scene.camera.apertureRadius = 0.
        testbed.clock.pause()
        images = {method: check(testbed, method) for method in methods}
        assert not np.allclose(images["ray_trace"], images["ray_trace_chart"]), "Chart option aliases polar mode"
        if scene == "cornell-box":
            for method in methods[1:]:
                check(testbed, method, laser=False)
    print("Surface reuse GPU checks passed.", flush=True)


if __name__ == "__main__":
    main()
