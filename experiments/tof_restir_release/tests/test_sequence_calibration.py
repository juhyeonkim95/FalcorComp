"""Calibration keeps ours fixed and respects the adjustment-run limit."""
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from common.sequence_calibration import next_spp
import online_rendering_sequence as sequence


class CalibrationTests(unittest.TestCase):
    def test_estimate_accounts_for_fixed_cost(self):
        trials = [{"spp": 10, "mean_frame_ms": 15.}, {"spp": 20, "mean_frame_ms": 25.}]
        self.assertEqual(next_spp(trials, 35.), 30)

    def test_fixed_target_and_bounded_trials(self):
        args = SimpleNamespace(methods=["pt", "naive", "ours"], spp=32,
                               calibration_runs=3, timing_tolerance=.01)
        calls = []

        def measure(testbed, scene, method, options):
            calls.append((method, options.spp))
            ms = 30. if method == "ours" else 3. + .5 * options.spp
            return [{"method": method, "frame": frame, "render_ms": ms,
                     "included_in_timing_summary": frame > 0} for frame in range(3)]

        with tempfile.TemporaryDirectory() as directory, patch.object(sequence, "time_sequence", side_effect=measure):
            selected, _ = sequence.calibrate_sequences(None, None, args, Path(directory))
        self.assertEqual(calls[:3], [("pt", 32), ("naive", 32), ("ours", 32)])
        self.assertEqual([call for call in calls if call[0] == "ours"], [("ours", 32)])
        self.assertEqual(selected["ours"]["spp"], 32)
        for method in ("pt", "naive"):
            self.assertLessEqual(sum(call[0] == method for call in calls), 4)
            self.assertTrue(selected[method]["within_tolerance"])

    def test_unmatchable_target_retains_best_measured(self):
        args = SimpleNamespace(methods=["pt", "ours"], spp=32,
                               calibration_runs=3, timing_tolerance=.01)
        calls = []

        def measure(testbed, scene, method, options):
            calls.append((method, options.spp))
            ms = 10. if method == "ours" else 100.
            return [{"method": method, "frame": 0, "render_ms": ms, "included_in_timing_summary": True}]

        with tempfile.TemporaryDirectory() as directory, patch.object(sequence, "time_sequence", side_effect=measure):
            selected, _ = sequence.calibrate_sequences(None, None, args, Path(directory))
        self.assertLessEqual(sum(method == "pt" for method, _ in calls), 4)
        self.assertFalse(selected["pt"]["within_tolerance"])
