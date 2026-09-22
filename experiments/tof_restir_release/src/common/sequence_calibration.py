"""Bounded SPP calibration against a fixed measured sequence time."""

import math


def next_spp(trials, target_ms):
    """Estimate a new integer SPP using measured slope when available."""
    best = min(trials, key=lambda trial: abs(trial["mean_frame_ms"] - target_ms))
    spp, milliseconds = best["spp"], best["mean_frame_ms"]
    proposal = spp * target_ms / milliseconds
    # A measured slope accounts for fixed pipeline cost better than proportional scaling.
    others = [trial for trial in trials if trial["spp"] != spp]
    if others:
        other = min(others, key=lambda trial: abs(trial["spp"] - spp))
        slope = (milliseconds - other["mean_frame_ms"]) / (spp - other["spp"])
        if slope > 0:
            proposal = spp + (target_ms - milliseconds) / slope
    if not math.isfinite(proposal):
        proposal = spp
    candidate = max(1, min(16384, round(max(spp / 4, min(spp * 4, proposal)))))
    tested = {trial["spp"] for trial in trials}
    if candidate in tested:
        direction = 1 if milliseconds < target_ms else -1
        candidate = spp + direction
        while candidate in tested:
            candidate += direction
    return candidate if 1 <= candidate <= 16384 else None
