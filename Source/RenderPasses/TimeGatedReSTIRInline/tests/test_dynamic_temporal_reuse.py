"""GPU regression for fixed geometry/materials and moving cameras/lights.

Build TimeGatedReSTIRInline and source the build's bin/setpath.sh before running:
    python Source/RenderPasses/TimeGatedReSTIRInline/tests/test_dynamic_temporal_reuse.py
Uses the tutorial Cornell box (docs_falcorcomp/src/tutorials/scenes). No images or reference files are written.
"""
from pathlib import Path

import falcor
import numpy as np

ROOT = Path(__file__).resolve().parents[4]
SCENE = ROOT / "docs_falcorcomp/src/tutorials/scenes/cornell-box/scene-v4-nolight.pbrt"
LIGHT_POSITION = [0., 1.7, 6.8]
LIGHT_DIRECTION = [0., 0., -1.]
LIGHT_POWER = [170., 120., 40.]


def create_testbed(resolution):
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(str(SCENE))
    testbed.resize_frame_buffer(*resolution)
    camera = testbed.scene.camera
    camera.aspectRatio = resolution[0] / resolution[1]
    camera.apertureRadius = 0.
    camera.shutterSpeed = 0.
    testbed.clock.pause()
    return testbed


def create_graph(testbed, shift_mapping_method, samples_per_pixel, spatial_iterations, temporal_reuse, scene_dynamic,
                 laser, collocated=False, gate_center=18., gate_width=4.):
    graph = testbed.create_render_graph("dynamic_temporal_reuse_test")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True})
    graph.create_pass("Laser", "LaserLight", {
        "laserPosition": LIGHT_POSITION, "laserDirection": LIGHT_DIRECTION, "laserPower": LIGHT_POWER,
        "laserAngle": 0., "laserCollocated": collocated, "isLightSourceLaser": laser,
    })
    graph.create_pass("Tracer", "TimeGatedReSTIRInline", {
        "samplingMethod": "direct", "samplesPerPixel": samples_per_pixel, "maxBounces": 6, "computeDirect": False,
        "timeGateMode": "box", "timeGateWindow": gate_width,
        "timeMin": gate_center, "timeMax": gate_center, "timeBin": 1,
        "spatialReuseIteration": spatial_iterations, "spatialReuseNeighborCount": 3,
        "spatialReuseGatherRadius": 10., "reconnectionRoughnessThreshold": .05,
        "shiftMappingMethod": shift_mapping_method, "useTemporalReuse": temporal_reuse, "isSceneDynamic": scene_dynamic,
    })
    graph.create_pass("Accumulate", "AccumulatePass", {"enabled": True, "precisionMode": "SingleCompensated"})
    for source, target in (("VBuffer.vbuffer", "Tracer.vbuffer"), ("VBuffer.viewW", "Tracer.viewW"),
                           ("Laser", "Tracer"), ("Tracer.color", "Accumulate.input")):
        graph.add_edge(source, target)
    if scene_dynamic and temporal_reuse:
        graph.add_edge("VBuffer.mvec", "Tracer.mvec")
    graph.mark_output("Accumulate.output")
    testbed.render_graph = graph
    return graph


def frame(testbed, graph):
    graph.get_pass("Accumulate").reset()
    testbed.frame()
    testbed.device.wait()
    image = graph.get_output("Accumulate.output").to_numpy()[..., :3].copy()
    assert np.isfinite(image).all()
    return image


def check_cached_lighting():
    """Dynamic specialization must not alter spatial reuse when the light is fixed.

    This catches accidental suffix updates with the default zero-power light in
    combineReservoirWithShiftMapping(updateLight=false).
    """
    testbed = create_testbed([48, 48])
    for shift_mapping_method in ("no", "area_adaptive"):
        images = []
        for dynamic in (False, True):
            graph = create_graph(testbed, shift_mapping_method, 64, 1, False, dynamic, laser=False, collocated=True,
                                 gate_center=12., gate_width=.05)
            images.append(frame(testbed, graph))
        np.testing.assert_allclose(images[0], images[1], rtol=2e-5, atol=1e-5)
        print(f"{shift_mapping_method}: dynamic specialization preserves cached spatial lighting", flush=True)


def main():
    testbed = create_testbed([24, 24])
    for laser in (False, True):
        # Reevaluation must reproduce the cached suffix when nothing moves.
        results = []
        for dynamic in (False, True):
            graph = create_graph(testbed, "no", 4, 0, True, dynamic, laser)
            results.append([frame(testbed, graph) for _ in range(3)])
        np.testing.assert_allclose(results[0], results[1], rtol=2e-5, atol=2e-6)
        print(f"laser={laser}: static suffix and replay agree", flush=True)

        # Compare retained history against no temporal reuse after the light moves.
        moved = []
        for temporal in (False, True):
            graph = create_graph(testbed, "local_tangent", 4, 1, temporal, True, laser)
            frame(testbed, graph)
            position = list(LIGHT_POSITION)
            position[0] += .15
            graph.get_pass("Laser").update_laser_info(position, LIGHT_DIRECTION)
            moved.append(frame(testbed, graph))
        assert not np.allclose(moved[0], moved[1]), "Moving the light discarded all temporal history"

        # Turning the source off must not leave stale lighting in the history.
        graph.update_pass("Laser", {"laserPower": [0., 0., 0.]})
        assert np.count_nonzero(frame(testbed, graph)) == 0, "Stale illumination after light-off"
        graph.update_pass("Laser", {"laserPower": LIGHT_POWER})
        assert frame(testbed, graph).sum() > 0, "Fresh samples lost after light-on"
        print(f"laser={laser}: moving light, spatial reuse, light-off/on passed", flush=True)

    # A collocated light follows camera motion without invalidating dynamic history.
    graph = create_graph(testbed, "local_tangent", 4, 1, True, True, laser=True, collocated=True)
    frame(testbed, graph)
    camera = testbed.scene.camera
    p, t = camera.position, camera.target
    camera.position = [p.x + .02, p.y, p.z]
    camera.target = [t.x + .02, t.y, t.z]
    assert frame(testbed, graph).sum() > 0
    print("Moving camera with collocated laser passed", flush=True)


if __name__ == "__main__":
    main()
    check_cached_lighting()
