"""GPU regression for fixed geometry/materials and moving cameras/lights.

Build TimeGatedReSTIRInline and source the build's bin/setpath.sh before running.
No experiment images or reference files are written.
"""
from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "experiments/tof_restir_release/src"))
from common.config import load_scene_config
from common.rendering import SpatialOptions, create_graph, create_testbed, read_image


def frame(testbed, graph):
    graph.get_pass("Accumulate").reset()
    testbed.frame()
    testbed.device.wait()
    image = read_image(graph)
    assert np.isfinite(image).all()
    return image


def check_bedroom_cached_lighting():
    """Dynamic specialization must not alter spatial reuse when the light is fixed.

    This catches accidental suffix updates with the default zero-power light in
    combine_reservoir_with_shiftmapping(updateLight=false).
    """
    scene = load_scene_config(ROOT / "experiments/tof_restir_release/scenes/exp7/bedroom.json",
                              [96, 54], gate_width=.05)
    testbed = create_testbed(scene)
    for method in ("naive", "ours"):
        images = []
        for dynamic in (False, True):
            graph = create_graph(testbed, method, scene, 64, SpatialOptions(iterations=1, neighbors=3),
                                 temporal_reuse=False, scene_dynamic=dynamic)
            testbed.render_graph = graph
            images.append(frame(testbed, graph))
        np.testing.assert_allclose(images[0], images[1], rtol=2e-5, atol=1e-5)
        print(f"Bedroom {method}: dynamic specialization preserves cached spatial lighting", flush=True)


def main():
    scene = load_scene_config(ROOT / "experiments/tof_restir_release/scenes/exp7/cornell_box.json",
                              [24, 24], gate_width=4.)
    scene.gate_center = 18.
    testbed = create_testbed(scene)
    for laser in (False, True):
        scene.is_laser = laser
        # Reevaluation must reproduce the cached suffix when nothing moves.
        results = []
        for dynamic in (False, True):
            graph = create_graph(testbed, "naive", scene, 4, SpatialOptions(iterations=0),
                                 temporal_reuse=True, scene_dynamic=dynamic)
            testbed.render_graph = graph
            results.append([frame(testbed, graph) for _ in range(3)])
        np.testing.assert_allclose(results[0], results[1], rtol=2e-5, atol=2e-6)
        print(f"laser={laser}: static suffix and replay agree", flush=True)

        # Compare retained history against no temporal reuse after the light moves.
        moved = []
        for temporal in (False, True):
            graph = create_graph(testbed, "ours", scene, 4, SpatialOptions(iterations=1, neighbors=3),
                                 temporal_reuse=temporal, scene_dynamic=True)
            testbed.render_graph = graph
            frame(testbed, graph)
            position = list(scene.light_position)
            position[0] += .15
            graph.get_pass("Laser").update_laser_info(position, scene.light_direction)
            moved.append(frame(testbed, graph))
        assert not np.allclose(moved[0], moved[1]), "Moving the light discarded all temporal history"

        # Turning the source off must not leave stale lighting in the history.
        graph.update_pass("Laser", {"laserPower": [0., 0., 0.]})
        assert np.count_nonzero(frame(testbed, graph)) == 0, "Stale illumination after light-off"
        graph.update_pass("Laser", {"laserPower": scene.light_power})
        assert frame(testbed, graph).sum() > 0, "Fresh samples lost after light-on"
        print(f"laser={laser}: moving light, spatial reuse, light-off/on passed", flush=True)

    # A collocated light follows camera motion without invalidating dynamic history.
    scene.light_collocated = True
    graph = create_graph(testbed, "ours", scene, 4, SpatialOptions(iterations=1, neighbors=3),
                         temporal_reuse=True, scene_dynamic=True)
    testbed.render_graph = graph
    frame(testbed, graph)
    camera = testbed.scene.camera
    p, t = camera.position, camera.target
    camera.position = [p.x + .02, p.y, p.z]
    camera.target = [t.x + .02, t.y, t.z]
    assert frame(testbed, graph).sum() > 0
    print("Moving camera with collocated laser passed", flush=True)


if __name__ == "__main__":
    main()
    check_bedroom_cached_lighting()
