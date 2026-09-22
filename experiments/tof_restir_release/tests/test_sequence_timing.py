"""Sequence timing must run without export and must not benchmark GT."""
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import online_rendering_sequence as sequence
from common.config import load_scene_config


class SequenceTimingTests(unittest.TestCase):
    def test_timing_uses_fresh_graph_without_export(self):
        scene = SimpleNamespace(gate_min=1., gate_max=2.)
        args = SimpleNamespace(frames=3, timing_skip_frames=1)
        graph = Mock()
        tracer, accumulator = Mock(), Mock()
        graph.get_pass.side_effect = [tracer, accumulator]
        with patch.object(sequence, "create_sequence_graph", return_value=graph) as create, \
             patch.object(sequence, "timed_frame", side_effect=[10., .01, .02]), \
             patch.object(sequence, "read_image") as read, \
             patch.object(sequence, "save_image") as image, \
             patch.object(sequence, "save_csv") as csv, \
             patch.object(sequence, "encode_video") as video:
            rows = sequence.time_sequence(None, scene, "ours", args)
        create.assert_called_once_with(None, scene, "ours", args)
        for operation in (read, image, csv, video):
            operation.assert_not_called()
        self.assertEqual([call.args[0] for call in tracer.set_time_gate_info.call_args_list], [1., 1. + 1. / 3., 1. + 2. / 3.])
        self.assertEqual(accumulator.reset.call_count, 3)
        self.assertEqual(sequence.summarize_timings(rows)["mean_frame_ms"], 15.)

    def test_reference_only_renders_images_once(self):
        scene = load_scene_config(Path(__file__).resolve().parents[1] / "scenes/exp7/cornell_box.json", gate_width=.01)
        args = SimpleNamespace(iterations=1, neighbors=3, spp=1024, temporal_history_length=20.,
                               frames=2, fps=30, gate_width=.01, timing_skip_frames=0)
        testbed, graph = Mock(), Mock()
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(sequence, "create_sequence_graph", return_value=graph) as create, \
             patch.object(sequence, "read_image"), patch.object(sequence, "save_image"), \
             patch.object(sequence, "encode_video"), patch.object(sequence, "time_sequence") as timing:
            rows, summary = sequence.render_sequence(testbed, scene, "pt", args, Path(directory),
                                                       "ffmpeg", reference_config={"test": True})
        create.assert_called_once()
        self.assertEqual(testbed.frame.call_count, 2)
        timing.assert_not_called()
        self.assertIsNone(summary)
        self.assertNotIn("render_ms", rows[0])
