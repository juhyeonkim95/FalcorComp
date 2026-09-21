"""Error evaluation on linear RGB; no Falcor dependency and no percentage scaling."""

import csv
import json
from pathlib import Path

import numpy as np

from .io import load_rgb, save_csv


def to_gray(image):
    """Convert RGB to grayscale; leave grayscale inputs unchanged."""
    image = np.asarray(image)
    if image.ndim == 3 and image.shape[-1] == 3:
        return (image[..., 0] * .2126 + image[..., 1] * .7152 + image[..., 2] * .0722)[..., None]
    return image


def pixel_mape(I, Ig):
    I = to_gray(I)
    Ig_gray = to_gray(Ig)
    denom = 0.01 * np.mean(Ig_gray) + Ig_gray
    return to_gray(np.abs(I - Ig_gray) / denom)


def measure_error(image, reference):
    image = np.asarray(image, dtype=np.float64)
    reference = np.asarray(reference, dtype=np.float64)
    if image.shape != reference.shape or image.ndim != 3 or image.shape[-1] != 3:
        raise ValueError("Image and reference must have matching H x W x 3 shapes")
    if not np.isfinite(image).all() or not np.isfinite(reference).all():
        raise ValueError("Image and reference must be finite")
    energy = np.mean(reference ** 2)
    gray_reference = to_gray(reference)
    denominator = .01 * np.mean(gray_reference) + gray_reference
    if energy <= 0 or np.any(denominator <= 0):
        raise ValueError("Reference must have positive energy and positive MAPE denominators")
    mse = float(np.mean((image - reference) ** 2))
    signed = (to_gray(image) - gray_reference) / denominator
    return {
        "mse": mse,
        "rmse": float(np.sqrt(mse)),
        "relative_mse": mse / float(energy),
        "relative_rmse": float(np.sqrt(mse / energy)),
        "mape": float(np.mean(pixel_mape(image, reference))),
        "mean_signed_relative_error": float(np.mean(signed)),
    }


def evaluate_run(directory):
    """Rebuild errors.csv from a run's saved checkpoints and local reference."""
    directory = Path(directory)
    manifest = json.loads((directory / "run.json").read_text())
    reference = load_rgb(directory / "reference.npy", manifest["scene"]["resolution"])
    reference_info = json.loads((directory / "reference.json").read_text())
    # Imported legacy GT may have no recorded frame/RNG history.
    reference_start = reference_info.get("first_frame_seed_index")
    reference_spp_per_frame = reference_info.get("spp_per_frame")
    reference_end = (reference_start + reference_info["spp"] // reference_spp_per_frame
                     if reference_start is not None and reference_spp_per_frame else None)
    comparison_start = manifest["budget"]["warmup_frames"]
    with (directory / "checkpoints.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    errors_by_image = {}
    for row in rows:
        image_file = row["image"]
        if image_file not in errors_by_image:
            errors_by_image[image_file] = measure_error(load_rgb(directory / image_file), reference)
        row.update(errors_by_image[image_file])
        # A cached reference from a shorter earlier run can share frame RNG seeds
        # with a longer comparison. Expose this rather than implying independent errors.
        row["reference_frame_overlap"] = None if reference_end is None else (
            max(comparison_start, reference_start) <
            min(comparison_start + int(row["frames"]), reference_end)
        )
    save_csv(directory / "errors.csv", rows)
    return rows
