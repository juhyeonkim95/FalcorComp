"""Camera trajectory and GT identity checks; no renderer required."""
import sys
import unittest
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import online_rendering_sequence as sequence
from common.sequence_motion import camera_pose, make_camera_motion, sequence_reference_path, validate_sequence_motion, camera_motions_match, laser_position, make_laser_motion


class SequenceMotionTests(unittest.TestCase):
    def test_speed_and_optional_direction(self):
        camera = SimpleNamespace(position=SimpleNamespace(x=0., y=1., z=4.),
                                 target=SimpleNamespace(x=0., y=1., z=2.))
        motion = make_camera_motion(camera, .1)
        np.testing.assert_allclose(camera_pose(motion, 2)[0], [0., 1., 3.8])
        sideways = make_camera_motion(camera, .1, [5., 0., 0.])
        position, target = camera_pose(sideways, 2)
        np.testing.assert_allclose(position, [.2, 1., 4.])
        np.testing.assert_allclose(np.subtract(target, position), [0., 0., -2.])
        self.assertEqual(camera_pose(make_camera_motion(camera, 0.), 99)[0], [0., 1., 4.])
        with self.assertRaises(ValueError):
            make_camera_motion(camera, .1, [0., 0., 0.])
        legacy = {"position": motion["position"], "target": motion["target"], "forward_step": .05}
        self.assertTrue(camera_motions_match(motion, legacy))
        self.assertFalse(camera_motions_match(sideways, legacy))

    def test_laser_and_gate_move_together_with_legacy_frame_delay(self):
        scene = SimpleNamespace(gate_min=15.6, gate_max=17.6,
                                light_position=[0., 1., 6.8], light_direction=[0., 0., -1.],
                                laser_velocity=[.007, .007, 0.], laser_motion_start_frame=1)
        motion = make_laser_motion(scene)
        self.assertEqual(laser_position(motion, 0), laser_position(motion, 1))
        np.testing.assert_allclose(laser_position(motion, 99), [.686, 1.686, 6.8])
        args = SimpleNamespace(camera_motion=None, laser_motion=motion, frames=100, timing_skip_frames=10)
        graph = Mock()
        with patch.object(sequence, "create_sequence_graph", return_value=graph), \
             patch.object(sequence, "timed_frame", return_value=.01):
            sequence.time_sequence(None, scene, "ours", args)
        calls = graph.get_pass.return_value.set_time_gate_info.call_args_list
        self.assertEqual(calls[0].args, (15.6, 15.6, 1))
        self.assertAlmostEqual(calls[-1].args[0], 17.58)
        self.assertEqual(graph.get_pass.return_value.update_laser_info.call_count, 100)
        ref_scene = SimpleNamespace(name="nlos-v2", gate_width=.02)
        self.assertIn("reference_sequence", sequence_reference_path(ref_scene, None, motion).parts)

    def test_motion_modes_select_dynamic_lighting(self):
        from common.sequence_motion import configure_sequence_motion, sequence_light_is_dynamic, apply_sequence_motion
        camera = SimpleNamespace(position=SimpleNamespace(x=0., y=1., z=4.),
                                 target=SimpleNamespace(x=0., y=1., z=2.))
        for speed, collocated, velocity, expected in [
            (0., False, None, False), (.1, False, None, False),
            (.1, True, None, True), (0., False, [.1, 0., 0.], True),
            (.1, False, [.1, 0., 0.], True), (0., True, None, False),
            (0., False, [0., 0., 0.], False),
        ]:
            with self.subTest(speed=speed, collocated=collocated, velocity=velocity):
                scene = SimpleNamespace(camera_speed=speed, camera_direction=None,
                    light_collocated=collocated, laser_velocity=velocity,
                    light_position=[0., 1., 4.], light_direction=[0., 0., -1.],
                    laser_motion_start_frame=0)
                args = SimpleNamespace()
                configure_sequence_motion(scene, camera, args)
                self.assertEqual(sequence_light_is_dynamic(scene, args), expected)
                graph = Mock()
                testbed = SimpleNamespace(scene=SimpleNamespace(camera=SimpleNamespace()))
                apply_sequence_motion(testbed, args, 2, graph)
                self.assertEqual(graph.get_pass.return_value.update_laser_info.call_count, int(expected))

    def test_old_forward_motion_keeps_unnormalized_direction(self):
        motion = {"position": [0., 1., 4.], "target": [0., 1., 2.], "forward_step": .02}
        self.assertEqual(camera_pose(motion, 0), (motion["position"], motion["target"]))
        position, target = camera_pose(motion, 99)
        np.testing.assert_allclose(position, [0., 1., .04])
        np.testing.assert_allclose(np.subtract(target, position), [0., 0., -2.])

    def test_dynamic_timing_restarts_motion_and_keeps_gate_fixed(self):
        motion = {"position": [0., 0., 0.], "target": [0., 0., 2.], "forward_step": .02}
        args = SimpleNamespace(camera_motion=motion, frames=3, spp=32, iterations=1,
                               neighbors=3, temporal_history_length=20., timing_skip_frames=1)
        scene = SimpleNamespace(gate_center=12., light_collocated=True)
        camera = SimpleNamespace(position=[99., 0., 0.], target=[100., 0., 0.])
        testbed = SimpleNamespace(scene=SimpleNamespace(camera=camera))
        graph = Mock()
        poses = []
        def create(*args, **kwargs):
            self.assertEqual(camera.position, motion["position"])
            self.assertTrue(kwargs["scene_dynamic"])
            return graph
        def time(_):
            poses.append(camera.position.copy())
            return .01
        with patch.object(sequence, "create_graph", side_effect=create), \
             patch.object(sequence, "timed_frame", side_effect=time):
            sequence.time_sequence(testbed, scene, "ours", args)
            sequence.time_sequence(testbed, scene, "ours", args)
        self.assertEqual(poses[:3], poses[3:])
        for call in graph.get_pass.return_value.set_time_gate_info.call_args_list:
            self.assertEqual(call.args, (12., 12., 1))

    def test_legacy_gt_nan_pixels_are_excluded_from_both_images(self):
        from evaluation.evaluate_exp7_sequence import measure_frame_error
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            gt = np.ones((2, 2, 3))
            image = gt.copy()
            gt[0, 0] = np.nan
            image[0, 0] = 1000.  # Must not contribute to any error metric.
            np.save(directory / "gt.npy", gt)
            np.save(directory / "image.npy", image)
            metrics, excluded = measure_frame_error(directory / "image.npy", directory / "gt.npy", [2, 2])
        self.assertEqual(excluded, 1)
        self.assertTrue(all(value == 0 for value in metrics.values()))

    def test_reference_shared_for_all_sequence_motion(self):
        scene = SimpleNamespace(name="bedroom", gate_width=.05)
        self.assertIn("reference_sequence", sequence_reference_path(scene, {}).parts)
        self.assertIn("reference_sequence", sequence_reference_path(scene).parts)
        with self.assertRaisesRegex(ValueError, "trajectories"):
            base = {"position": [0., 0., 0.], "target": [0., 0., 1.]}
            validate_sequence_motion({"camera_motion": {**base, "forward_step": .02}},
                                     {"camera_motion": {**base, "forward_step": .01}})


if __name__ == "__main__":
    unittest.main()
