"""CPU checks for benchmark accounting, metrics, and the three graph definitions."""

from dataclasses import replace
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from common.config import load_scene_config
from common.io import save_csv, save_json
from common.metrics import evaluate_run, measure_error
from common.rendering import Budget, SpatialOptions, create_graph, render_method, render_reference, timed_frame
from offline_rendering_with_spatial_reuse_comparison import check_reference, find_reference, clear_comparison_outputs


class Graph:
    def __init__(self):
        self.passes = {}
        self.reset_count = 0

    def create_pass(self, name, plugin, properties):
        self.passes[name] = (plugin, properties)

    def add_edge(self, *args):
        pass

    def mark_output(self, *args):
        pass

    def get_pass(self, name):
        return self

    def reset(self):
        self.reset_count += 1


class Testbed:
    def __init__(self):
        self.device = self
        self.events = []

    def create_render_graph(self, name):
        return Graph()

    def frame(self):
        self.events.append("frame")

    def wait(self):
        self.events.append("wait")


class ExampleTests(unittest.TestCase):
    def test_exp4_gauges_reach_tracer_with_same_reuse_settings(self):
        from offline_rendering_with_gauge_comparison import VARIANTS
        scene = load_scene_config(ROOT / "scenes/exp4/cornell_box.json", [3, 2], gate_width=.02)
        expected = {
            "horizontal": ("constant", [1., 0.]),
            "vertical": ("constant", [0., 1.]),
            "avg_grad": ("avg_grad", [1., 0.]),
        }
        self.assertEqual(set(VARIANTS), set(expected))
        for label, (method, overrides) in VARIANTS.items():
            graph = create_graph(Testbed(), method, scene, 32, replace(SpatialOptions(), **overrides))
            plugin, properties = graph.passes["Tracer"]
            self.assertEqual(plugin, "TimeGatedReSTIRInline")
            self.assertEqual((properties["gaugeMode"], properties["gaugeAxis"]), expected[label])
            self.assertEqual(properties["shiftmapMethod"], "local_tangent")
            self.assertEqual(properties["spatialReuseIteration"], 3)
            self.assertEqual(properties["spatialReuseNeighborCount"], 5)
            self.assertFalse(properties["debugNewtonIterations"])
            self.assertIn("Accumulate", graph.passes)


    def test_rerun_reuses_gt_and_clears_comparison_outputs(self):
        scene = load_scene_config(ROOT / "scenes/exp1/cornell_box.json", [3, 2], gate_width=.02)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            np.save(output / "reference.npy", np.ones((2, 3, 3)))
            save_json(output / "reference.json", {"scene_signature": scene.reference_signature(),
                      "spp": 64, "spp_per_frame": 4, "first_frame_seed_index": 100})
            original = (output / "reference.npy").read_bytes()
            (output / "images").mkdir()
            (output / "images/old.png").write_bytes(b"old image")
            (output / "errors.csv").write_text("old errors")
            (output / "notes.txt").write_text("keep")
            cached, source = find_reference(output, scene)
            self.assertIsNotNone(cached)
            self.assertEqual(source, str(output / "reference.npy"))
            clear_comparison_outputs(output, keep_reference=True)
            self.assertFalse((output / "images").exists())
            self.assertFalse((output / "errors.csv").exists())
            self.assertEqual((output / "reference.npy").read_bytes(), original)
            self.assertEqual((output / "notes.txt").read_text(), "keep")
            self.assertIsNone(find_reference(output, scene, regenerate=True)[0])
            self.assertIsNone(find_reference(output, replace(scene, gate_width=.05))[0])
            with self.assertRaises(ValueError):
                find_reference(output, replace(scene, gate_width=.05), explicit=output / "reference.npy")
            clear_comparison_outputs(output, keep_reference=False)
            self.assertFalse((output / "reference.npy").exists())
            self.assertFalse((output / "reference.json").exists())

    def test_scene_shift_method_only_changes_ours(self):
        scene = load_scene_config(ROOT / "scenes/exp1/cornell_box.json", gate_width=.02)
        adaptive = replace(scene, shiftmap_method="area_adaptive")
        adaptive.validate()
        self.assertEqual(scene.reference_signature(), adaptive.reference_signature())
        ours = create_graph(Testbed(), "ours", adaptive, 4, SpatialOptions())
        naive = create_graph(Testbed(), "naive", adaptive, 4, SpatialOptions())
        self.assertEqual(ours.passes["Tracer"][1]["shiftmapMethod"], "area_adaptive")
        self.assertEqual(naive.passes["Tracer"][1]["shiftmapMethod"], "no")
        with self.assertRaises(ValueError):
            replace(scene, shiftmap_method="invalid").validate()

    def test_reference_progress_counts_completed_frames(self):
        testbed, graph = Testbed(), Graph()
        with patch("common.rendering.trange", side_effect=lambda count, **kwargs: range(count)) as progress, \
             patch("common.rendering.read_image", return_value=np.ones((2, 3, 3))):
            render_reference(testbed, graph, 1, 3, Budget("spp", (4,), 4), 16)
        self.assertEqual([call.args[0] for call in progress.call_args_list], [2, 4])
        self.assertEqual(graph.reset_count, 1)
        self.assertEqual(testbed.events.count("frame"), 6)
        for index, event in enumerate(testbed.events):
            if event == "frame":
                self.assertEqual(testbed.events[index + 1], "wait")

    def test_fractional_metrics(self):
        reference = np.ones((2, 3, 3))
        self.assertEqual(measure_error(reference, reference)["mape"], 0)
        errors = measure_error(2 * reference, reference)
        self.assertAlmostEqual(errors["mape"], 1 / 1.01)
        self.assertAlmostEqual(errors["mean_signed_relative_error"], 1 / 1.01)
        self.assertEqual(errors["relative_mse"], 1)
        self.assertEqual(errors["relative_rmse"], 1)
        dark = measure_error(np.zeros_like(reference), reference)
        self.assertAlmostEqual(dark["mean_signed_relative_error"], -1 / 1.01)

    def test_invalid_images(self):
        for reference in (np.zeros((2, 3, 3)), np.full((2, 3, 3), np.nan)):
            with self.assertRaises(ValueError):
                measure_error(np.ones((2, 3, 3)), reference)
        with self.assertRaises(ValueError):
            measure_error(np.ones((2, 3, 3)), np.ones((2, 2, 3)))

    def test_budget_validation(self):
        for mode, values, spp in (("spp", (1, 3), 2), ("seconds", (float("nan"),), 1),
                                  ("spp", (2, 1), 1), ("seconds", (1, 1), 1)):
            with self.assertRaises(ValueError):
                Budget(mode, values, spp)

    def test_synchronization_is_inside_timer(self):
        testbed = Testbed()
        with patch("common.rendering.perf_counter", side_effect=[10., 12.]):
            self.assertEqual(timed_frame(testbed), 2.)
        self.assertEqual(testbed.events, ["frame", "wait"])

    def test_time_checkpoints_exclude_warmup_and_share_crossed_frame(self):
        graph = Graph()
        budget = Budget("seconds", (.5, 1., 2.), 4, warmup_frames=2)
        with patch("common.rendering.timed_frame", side_effect=[100., 90., 1.5, .75]), \
             patch("common.rendering.read_image", return_value=np.ones((2, 3, 3))), \
             patch("common.rendering.save_image") as save:
            rows, timings, warmup, frames = render_method(Testbed(), graph, "pt", budget, Path("unused"))
        self.assertEqual(graph.reset_count, 1)
        self.assertEqual(frames, 2)
        self.assertEqual(len(warmup), 2)
        self.assertEqual(len(timings), 2)
        self.assertEqual(save.call_count, 2)
        self.assertEqual([row["spp"] for row in rows], [4, 4, 8])
        self.assertEqual([row["overshoot_seconds"] for row in rows], [1., .5, .25])
        self.assertEqual(rows[0]["image"], rows[1]["image"])
        self.assertEqual(rows[-1]["elapsed_seconds"], 2.25)

    def test_mapping_statistics_sum_measured_frames_at_each_checkpoint(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        graph = Graph()
        graph.get_output = Mock(side_effect=[
            SimpleNamespace(to_numpy=lambda: np.array([[[2, 1, 3, 4]]], dtype=np.uint32)),
            SimpleNamespace(to_numpy=lambda: np.array([[[4., 6.]]])),
            SimpleNamespace(to_numpy=lambda: np.array([[[1, 1, 2, 2]]], dtype=np.uint32)),
            SimpleNamespace(to_numpy=lambda: np.array([[[5., 6.]]])),
        ])
        budget = Budget("seconds", (1., 2.), 1, warmup_frames=2)
        with patch("common.rendering.timed_frame", side_effect=[90., 100., 1., 1.]), \
             patch("common.rendering.read_image", return_value=np.ones((1, 1, 3))), \
             patch("common.rendering.save_image"):
            rows, _, _, _ = render_method(Testbed(), graph, "horizontal", budget, Path("unused"), statistics=True)
        self.assertEqual(graph.get_output.call_count, 4)  # No warm-up readback.
        self.assertEqual(rows[0]["mapping_success_count"], 2)
        self.assertEqual(rows[0]["mean_xi_distance"], 2.)
        self.assertEqual(rows[1]["mapping_success_count"], 3)
        self.assertEqual(rows[1]["xi_distance_sum"], 9.)
        self.assertEqual(rows[1]["mean_xi_distance"], 3.)
        self.assertEqual(rows[1]["mean_world_distance"], 4.)

    def test_runner_exports_with_zero_warmup_and_reuses_gt(self):
        import json
        from types import SimpleNamespace
        import offline_rendering_with_spatial_reuse_comparison as runner
        scene = load_scene_config(ROOT / "scenes/exp4/cornell_box.json", [3, 2], gate_width=.01)
        testbed = Testbed()
        testbed.info = SimpleNamespace(adapter_name="mock", api_name="mock")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "reference.npy").write_bytes(b"preserve GT")
            (output / "warmup_times.csv").write_text("stale warmup")
            args = SimpleNamespace(output=output, neighbors=5, iterations=3, radius=10.,
                                   reference=None, reference_dir=output, regenerate_reference=False, reference_spp=32)
            with patch.object(runner, "parse_args", return_value=(args, scene, Budget("spp", (32,), 32, 0))), \
                 patch.object(runner, "find_reference", return_value=((np.ones((2, 3, 3)), {"spp": 32}), "cached")), \
                 patch.object(runner, "create_testbed", return_value=testbed), \
                 patch("common.rendering.timed_frame", return_value=.1), \
                 patch("common.rendering.read_image", return_value=np.ones((2, 3, 3))), \
                 patch("common.rendering.save_image"), patch.object(runner, "save_image"), \
                 patch.object(runner, "evaluate_run", return_value=[]), \
                 patch.object(runner, "render_reference") as render_gt:
                runner.main(variants={label: ("ours", {}) for label in ("horizontal", "vertical", "avg_grad")})
            render_gt.assert_not_called()
            self.assertFalse((output / "warmup_times.csv").exists())
            self.assertEqual((output / "reference.npy").read_bytes(), b"preserve GT")
            self.assertEqual(len((output / "checkpoints.csv").read_text().splitlines()), 4)
            self.assertEqual(json.loads((output / "run.json").read_text())["status"], "complete")

    def test_exp5_all_sampling_combinations_and_direct_gt(self):
        from types import SimpleNamespace
        import offline_rendering_with_spatial_reuse_comparison as runner
        from offline_rendering_with_initial_sampling_comparison import VARIANTS, INITIAL_SAMPLING
        scene = load_scene_config(ROOT / "scenes/exp5/cornell_box.json", [3, 2], gate_width=.02)
        self.assertEqual(len(VARIANTS), 9)
        for label, (method, _) in VARIANTS.items():
            graph = create_graph(Testbed(), method, scene, 32, SpatialOptions(), sampling_method=INITIAL_SAMPLING[label])
            properties = graph.passes["Tracer"][1]
            self.assertEqual(properties["samplingMethod"], INITIAL_SAMPLING[label])
            self.assertEqual(properties["emissiveSampler"], "LightBVH")
            if method != "pt":
                self.assertEqual(properties["shiftmapMethod"], "no" if method == "naive" else scene.shiftmap_method)
                self.assertFalse(properties["debugNewtonIterations"])
        testbed = Testbed()
        testbed.info = SimpleNamespace(adapter_name="mock", api_name="mock")
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(output=Path(directory), neighbors=5, iterations=3, radius=10.,
                                   reference=None, reference_dir=Path(directory), regenerate_reference=False, reference_spp=32)
            with patch.object(runner, "parse_args", return_value=(args, scene, Budget("spp", (32,), 32, 0))), \
                 patch.object(runner, "create_testbed", return_value=testbed), \
                 patch("common.rendering.timed_frame", return_value=.1), \
                 patch("common.rendering.read_image", return_value=np.ones((2, 3, 3))), \
                 patch("common.rendering.save_image"), patch.object(runner, "save_image"), \
                 patch.object(runner, "evaluate_run", return_value=[]) as evaluate_errors, \
                 patch.object(runner, "render_reference", return_value=np.ones((2, 3, 3))) as render_gt:
                runner.main(variants=VARIANTS, sampling_methods=INITIAL_SAMPLING, evaluate_errors=False)
            evaluate_errors.assert_not_called()
            gt_graph = render_gt.call_args.args[1]
            self.assertEqual(gt_graph.passes["Tracer"][0], "TimeGatedPathTracerInline")
            self.assertEqual(gt_graph.passes["Tracer"][1]["samplingMethod"], "direct")

    def test_bistro_uses_scene_camera(self):
        from types import SimpleNamespace
        from common.rendering import create_testbed
        scene = load_scene_config(ROOT / "scenes/exp5/bistro.json", gate_width=.05)
        camera = SimpleNamespace(position=[0, 0, 0], target=[0, 0, -1])
        fake = SimpleNamespace(scene=SimpleNamespace(camera=camera),
                               load_scene=lambda path: None, resize_frame_buffer=lambda *size: None,
                               clock=SimpleNamespace(pause=lambda: None), profiler=SimpleNamespace(enabled=True))
        falcor = SimpleNamespace(Testbed=lambda **kwargs: fake,
                                 Logger=SimpleNamespace(Level=SimpleNamespace(Error=0)))
        with patch.dict(sys.modules, falcor=falcor):
            self.assertIs(create_testbed(scene), fake)
        self.assertIsNone(scene.camera_position)
        self.assertIsNone(scene.camera_target)
        self.assertEqual(camera.position, [0, 0, 0])
        self.assertEqual(camera.target, [0, 0, -1])
        self.assertEqual(camera.aspectRatio, 960 / 540)
        signature = scene.reference_signature()
        self.assertNotIn("camera_position", signature)
        self.assertNotIn("camera_target", signature)
        changed = replace(scene, camera_position=[0., 0., 1.], camera_target=[0., 0., 0.])
        self.assertNotEqual(changed.reference_signature(), signature)
        with self.assertRaises(ValueError):
            replace(changed, camera_target=None).validate()
        with self.assertRaises(ValueError):
            replace(changed, camera_target=changed.camera_position).validate()
        default = load_scene_config(ROOT / "scenes/exp1/cornell_box.json", gate_width=.02)
        self.assertNotIn("camera_position", default.reference_signature())

    def test_spp_checkpoints_are_exact(self):
        budget = Budget("spp", (4, 8, 16), 4, warmup_frames=1)
        with patch("common.rendering.timed_frame", return_value=.1), \
             patch("common.rendering.read_image", return_value=np.ones((2, 3, 3))), \
             patch("common.rendering.save_image"):
            rows, _, _, frames = render_method(Testbed(), Graph(), "pt", budget, Path("unused"))
        self.assertEqual(frames, 4)
        self.assertEqual([r["spp"] for r in rows], [4, 8, 16])
        self.assertTrue(all(r["overshoot_seconds"] == 0 for r in rows))

    def test_graphs_only_differ_in_renderer_and_shift_mapping(self):
        scene = load_scene_config(ROOT / "scenes/exp1/cornell_box.json", gate_width=0.02)
        graphs = {m: create_graph(Testbed(), m, scene, 4, SpatialOptions()) for m in ("pt", "naive", "ours")}
        for graph in graphs.values():
            self.assertEqual(graph.passes["Tracer"][1]["samplingMethod"], "direct")
        naive = graphs["naive"].passes["Tracer"][1].copy()
        ours = graphs["ours"].passes["Tracer"][1].copy()
        self.assertEqual(naive.pop("shiftmapMethod"), "no")
        self.assertEqual(ours.pop("shiftmapMethod"), "local_tangent")
        self.assertEqual(naive, ours)
        self.assertFalse(ours["useTemporalReuse"])
        self.assertFalse(ours["isSceneDynamic"])

    def test_evaluator_flags_cached_reference_frame_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            save_json(output / "run.json", {"scene": {"resolution": [3, 2]}, "budget": {"warmup_frames": 3}})
            save_json(output / "reference.json", {"first_frame_seed_index": 5, "spp": 128, "spp_per_frame": 4})
            np.save(output / "reference.npy", np.ones((2, 3, 3)))
            np.save(output / "image.npy", np.ones((2, 3, 3)) * 2)
            save_csv(output / "checkpoints.csv", [
                {"method": "pt", "frames": 2, "image": "image.npy"},
                {"method": "pt", "frames": 3, "image": "image.npy"},
            ])
            rows = evaluate_run(output)
            self.assertFalse(rows[0]["reference_frame_overlap"])
            self.assertTrue(rows[1]["reference_frame_overlap"])
            self.assertAlmostEqual(rows[0]["mape"], 1 / 1.01)

    def test_reference_requires_matching_physical_settings(self):
        scene = load_scene_config(ROOT / "scenes/exp1/cornell_box.json", [3, 2], gate_width=0.02)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reference.npy"
            np.save(path, np.ones((2, 3, 3)))
            save_json(path.with_suffix(".json"), {"scene_signature": scene.reference_signature(), "spp": 64,
                                                        "spp_per_frame": 4, "first_frame_seed_index": 100})
            check_reference(path, scene)
            with self.assertRaises(ValueError):
                check_reference(path, replace(scene, gate_width=scene.gate_width * 2))


if __name__ == "__main__":
    unittest.main()
