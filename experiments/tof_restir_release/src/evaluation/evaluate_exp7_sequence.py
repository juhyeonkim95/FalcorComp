"""Evaluate saved linear-RGB sequences; average each metric equally over all frames."""

import argparse
import csv
import json
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.config import SceneConfig
from common.io import load_rgb, save_csv
from common.metrics import measure_error
from common.sequence_motion import sequence_reference_path, validate_sequence_motion


def read_frames(folder):
    with (folder / "frames.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if not rows or len({int(row["frame"]) for row in rows}) != len(rows):
        raise ValueError(f"Empty or duplicate frame records: {folder}")
    return rows


def measure_frame_error(image_path, reference_path, resolution):
    image = load_rgb(image_path, resolution)
    reference = np.load(reference_path, allow_pickle=False)
    if reference.shape != image.shape:
        raise ValueError(f"GT dimensions do not match: {reference_path}")
    # Legacy GT may contain NaNs. Exclude the entire RGB pixel from both images,
    # including the reference mean used in MAPE; do not invent reference values.
    valid = np.isfinite(reference).all(axis=-1)
    if not valid.any():
        raise ValueError(f"GT contains no finite pixels: {reference_path}")
    metrics = measure_error(image[valid][:, None, :], reference[valid][:, None, :])
    return metrics, int(valid.size - valid.sum())


def evaluate_sequence(run, methods):
    frame_errors, summaries = [], []
    for method in methods:
        folder = run / method
        manifest = json.loads((folder / "run.json").read_text())
        if manifest["status"] != "complete":
            raise ValueError(f"Incomplete sequence: {folder}")
        scene = SceneConfig(**manifest["scene"])
        reference = sequence_reference_path(scene, manifest.get("camera_motion"), manifest.get("laser_motion"))
        gt_manifest = json.loads((reference / "run.json").read_text())
        if (gt_manifest["status"] != "complete" or
                gt_manifest["reference_config"]["scene_signature"] != scene.reference_signature()):
            raise ValueError(f"GT settings do not match {folder}")
        validate_sequence_motion(manifest, gt_manifest)
        rows = read_frames(folder)
        gt_rows = {int(row["frame"]): row for row in read_frames(reference)}
        if len(rows) != manifest["frames"] or {int(row["frame"]) for row in rows} != set(range(manifest["frames"])):
            raise ValueError(f"Missing sequence frames: {folder}")
        method_errors = []
        for row in rows:
            frame = int(row["frame"])
            gt = gt_rows.get(frame)
            if gt is None or any(not np.isclose(float(row[key]), float(gt[key]), rtol=0, atol=1e-9)
                                 for key in ("gate_center", "gate_width")):
                raise ValueError(f"GT gate mismatch for {method}, frame {frame}")
            metrics, excluded = measure_frame_error(folder / row["image"], reference / gt["image"], scene.resolution)
            method_errors.append(metrics)
            frame_errors.append({"method": method, "frame": frame, "gate_center": row["gate_center"],
                                 "spp": row["spp"], "reference_spp": gt["spp"], "excluded_gt_pixels": excluded, **metrics})
        # All animation frames count, including frames excluded from timing statistics.
        averages = {f"mean_{key}": float(np.mean([error[key] for error in method_errors]))
                    for key in method_errors[0]}
        summary = {"method": method, "frames": len(rows), "spp": manifest["spp_per_frame"],
                   "reference_spp": gt_manifest["spp_per_frame"],
                   "mean_frame_ms": manifest["timing_summary"]["mean_frame_ms"],
                   "excluded_gt_pixels": sum(row["excluded_gt_pixels"] for row in frame_errors if row["method"] == method), **averages}
        summaries.append(summary)
    save_csv(run / "frame_errors.csv", frame_errors)
    save_csv(run / "sequence_errors.csv", summaries)
    print(f"\n{run.name}: arithmetic mean over all sequence frames (linear RGB; luminance MAPE)")
    print("method  SPP   ms/frame   mean RMSE    mean relative MSE    mean MAPE")
    for row in summaries:
        print(f"{row['method']:6s} {row['spp']:4d} {row['mean_frame_ms']:10.3f} "
              f"{row['mean_rmse']:12.6g} {row['mean_relative_mse']:20.6g} {row['mean_mape']:12.6g}")
    print(f"Saved frame_errors.csv and sequence_errors.csv to {run}")
    return summaries


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--methods", nargs="+", choices=("pt", "naive", "ours"), default=["pt", "naive", "ours"])
    args = parser.parse_args()
    evaluate_sequence(args.run.resolve(), args.methods)
