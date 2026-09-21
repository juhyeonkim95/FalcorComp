"""Portable output files: linear RGB arrays, display-only previews, CSV, and JSON."""

import csv
import json
from pathlib import Path

import numpy as np
from PIL import Image


def save_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def save_csv(path, rows):
    if not rows:
        raise ValueError("Cannot export an empty table")
    with Path(path).open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def load_rgb(path, resolution=None):
    rgb = np.load(path, allow_pickle=False)
    if rgb.ndim != 3 or rgb.shape[-1] != 3 or not np.isfinite(rgb).all():
        raise ValueError(f"Expected a finite H x W x 3 linear RGB array: {path}")
    if resolution is not None and rgb.shape[:2] != (resolution[1], resolution[0]):
        raise ValueError(f"Image resolution does not match scene configuration: {path}")
    return rgb


def save_image(path, rgb):
    """Keep the linear .npy for error measurement; PNG is Reinhard + sRGB only."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not np.isfinite(rgb).all():
        raise ValueError(f"Cannot save a non-finite render: {path}")
    np.save(path, rgb)
    display = np.maximum(rgb, 0.0)
    display = display / (1.0 + display)
    display = np.where(display <= .0031308, 12.92 * display,
                       1.055 * display ** (1.0 / 2.4) - .055)
    Image.fromarray((np.clip(display, 0, 1) * 255).astype(np.uint8)).save(path.with_suffix(".png"))
