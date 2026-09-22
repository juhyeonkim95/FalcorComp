"""Counter aggregation tests; no Falcor required."""
from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from common.reuse_statistics import summarize_counts, summarize_distances, validate_counts


class ReuseStatisticsTests(unittest.TestCase):
    def test_collocated_light_uses_non_subscriptable_camera_vectors(self):
        from types import SimpleNamespace
        from dataclasses import replace
        from test_example import Testbed, ROOT
        from common.config import load_scene_config
        from common.rendering import create_graph, SpatialOptions
        scene = load_scene_config(ROOT / "scenes/exp2/cornell_box_dragon_diffuse.json", [3, 2], gate_width=.005)
        scene = replace(scene, light_collocated=True)
        testbed = Testbed()
        testbed.scene = SimpleNamespace(camera=SimpleNamespace(
            position=SimpleNamespace(x=1., y=2., z=3.),
            target=SimpleNamespace(x=1., y=2., z=1.),
        ))
        graph = create_graph(testbed, "ours", scene, 1, SpatialOptions(), statistics=True)
        laser = graph.passes["Laser"][1]
        self.assertEqual(laser["laserPosition"], [1., 2., 3.])
        self.assertEqual(laser["laserDirection"], [0., 0., -1.])
        self.assertTrue(graph.passes["Tracer"][1]["laserCollocated"])

    def test_debug_graph_preserves_rgb_accumulation(self):
        from test_example import Testbed, ROOT
        from common.config import load_scene_config
        from common.rendering import create_graph, SpatialOptions
        scene = load_scene_config(ROOT / "scenes/exp2/cornell_box_dragon_diffuse.json", [3, 2], gate_width=.005)
        for method in ("naive", "ours"):
            graph = create_graph(Testbed(), method, scene, 1, SpatialOptions(), statistics=True)
            self.assertIn("Accumulate", graph.passes)
            self.assertTrue(graph.passes["Tracer"][1]["debugNewtonIterations"])
        with self.assertRaises(ValueError):
            create_graph(Testbed(), "pt", scene, 1, SpatialOptions(), statistics=True)

    def test_distances_use_mapping_successes_not_attempts_or_visibility(self):
        counts = np.array([[[2, 1, 5, 8], [1, 0, 3, 4]]])
        result = summarize_distances(np.array([[[4., 6.], [2., 3.]]]), counts)
        self.assertEqual(result["mean_xi_distance"], 2.)
        self.assertEqual(result["mean_world_distance"], 3.)
        self.assertIsNone(summarize_distances(np.zeros((1, 1, 2)), np.zeros((1, 1, 4)))["mean_xi_distance"])
        with self.assertRaises(ValueError):
            summarize_distances(np.full((1, 2, 2), np.nan), counts)

    def test_global_ratio_not_average_of_pixel_ratios(self):
        stats = summarize_counts(np.array([[[10, 1, 10, 30], [1, 1, 1, 2]]]))
        self.assertAlmostEqual(stats["actual_success_rate"], 2 / 11)
        self.assertEqual(stats["newton_iteration_sum"], 32)

    def test_naive_can_fail_without_newton(self):
        stats = summarize_counts(np.array([[[10, 3, 10, 0]]]))
        self.assertEqual(stats["actual_success_rate"], .3)
        self.assertEqual(stats["newton_iteration_sum"], 0)

    def test_no_attempts_is_undefined(self):
        self.assertIsNone(summarize_counts(np.zeros((1, 1, 4)))["actual_success_rate"])

    def test_invalid_or_normalized_counters_rejected(self):
        for counts in (np.zeros((1, 1, 3)), [[[1, 2, 1, 0]]], [[[1, 0, 1, .5]]], [[[np.nan, 0, 1, 0]]]):
            with self.assertRaises(ValueError):
                validate_counts(counts)


if __name__ == "__main__":
    unittest.main()
