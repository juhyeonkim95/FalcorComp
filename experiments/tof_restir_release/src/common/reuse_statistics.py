"""Aggregation of dedicated Newton counter and mapping-distance outputs."""

import numpy as np

CHANNELS = ("mapping_success_count", "actual_success_count", "attempt_count", "newton_iteration_sum")


def validate_counts(counts):
    counts = np.asarray(counts, dtype=np.float64)
    if counts.ndim != 3 or counts.shape[-1] != 4:
        raise ValueError("Expected H x W x 4 raw debug counters")
    if not np.isfinite(counts).all() or (counts < 0).any():
        raise ValueError("Counters must be finite and nonnegative")
    if (counts[..., 1] > counts[..., 0]).any() or (counts[..., 0] > counts[..., 2]).any():
        raise ValueError("Expected actual successes <= mapping successes <= attempts")
    if not np.equal(counts, np.floor(counts)).all():
        raise ValueError("Expected integer-valued counters; do not accumulate/normalize as RGB")
    return counts


def summarize_counts(counts):
    totals = validate_counts(counts).sum(axis=(0, 1), dtype=np.float64)
    result = dict(zip(CHANNELS, (int(v) for v in totals)))
    # Ratio of global sums, not the average of individual pixel success rates.
    result["actual_success_rate"] = float(totals[1] / totals[2]) if totals[2] else None
    return result


DISTANCE_CHANNELS = ("xi_distance_sum", "world_distance_sum")


def summarize_distances(distances, counts):
    distances = np.asarray(distances, dtype=np.float64)
    counts = validate_counts(counts)
    if distances.shape != counts.shape[:2] + (2,):
        raise ValueError("Expected H x W x 2 mapping distances matching the counters")
    if not np.isfinite(distances).all() or (distances < 0).any():
        raise ValueError("Mapping distances must be finite and nonnegative")
    sums = distances.sum(axis=(0, 1))
    successes = counts[..., 0].sum()
    return {**dict(zip(DISTANCE_CHANNELS, map(float, sums))),
            "mean_xi_distance": float(sums[0] / successes) if successes else None,
            "mean_world_distance": float(sums[1] / successes) if successes else None}
