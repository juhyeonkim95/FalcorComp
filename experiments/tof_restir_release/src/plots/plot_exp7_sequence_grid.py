"""Plot selected sequence frames as columns, with one renderer per row."""

import argparse
import csv
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.config import SceneConfig
from common.sequence_motion import sequence_reference_path, validate_sequence_motion

import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt
from PIL import Image


def plot_grid(run, frames, gt_images=None):
    methods = [("pt", "PT"), ("naive", "Naive"), ("ours", "Ours")]
    if gt_images is None:
        manifest = json.loads((run / "pt/run.json").read_text())
        scene = SceneConfig(**manifest["scene"])
        reference = sequence_reference_path(scene, manifest.get("camera_motion"), manifest.get("laser_motion"))
        if (reference / "run.json").is_file():
            if json.loads((reference / "run.json").read_text()).get("status") != "complete":
                raise ValueError(f"Reference sequence is incomplete: {reference}")
            validate_sequence_motion(manifest, json.loads((reference / "run.json").read_text()))
            gt_images = reference / "images"
    if not frames or len(set(frames)) != len(frames) or any(frame < 0 for frame in frames):
        raise ValueError("Frames must be distinct nonnegative indices (zero-based)")
    rows = []
    expected_centers = None
    image_size = None
    first_manifest = json.loads((run / "pt/run.json").read_text())
    for method, label in methods:
        validate_sequence_motion(first_manifest, json.loads((run / method / "run.json").read_text()))
        with (run / method / "frames.csv").open(newline="") as stream:
            records = {int(row["frame"]): row for row in csv.DictReader(stream)}
        if any(frame not in records for frame in frames):
            raise ValueError(f"Requested frame is missing from {method}/frames.csv")
        centers = [float(records[frame]["gate_center"]) for frame in frames]
        if expected_centers is not None and centers != expected_centers:
            raise ValueError("Selected frames use different gate centers across methods")
        expected_centers = centers
        paths = [(run / method / records[frame]["image"]).with_suffix(".png") for frame in frames]
        rows.append((label, paths))
    if gt_images is not None:
        metadata = gt_images.parent / "frames.csv"
        if metadata.is_file():
            with metadata.open(newline="") as stream:
                gt_records = {int(row["frame"]): row for row in csv.DictReader(stream)}
            if any(frame not in gt_records for frame in frames) or [
                    float(gt_records[frame]["gate_center"]) for frame in frames] != expected_centers:
                raise ValueError("GT gate centers do not match the selected rendered frames; rerender the matching sequence")
        rows.append(("GT", [gt_images / f"frame_{frame:04d}.png" for frame in frames]))

    # Reuse the saved display previews: no per-image normalization or exposure changes.
    loaded = []
    for label, paths in rows:
        images = []
        for path in paths:
            with Image.open(path) as source:
                if image_size is not None and source.size != image_size:
                    raise ValueError(f"Image dimensions differ: {path}")
                image_size = source.size
                images.append(source.convert("RGB"))
        loaded.append((label, images))
    width, height = image_size
    fig, axes = plt.subplots(len(rows), len(frames), squeeze=False,
                             figsize=(2 * len(frames) + .6, 2 * height / width * len(rows) + .4))
    for row, (label, images) in enumerate(loaded):
        for column, image in enumerate(images):
            ax = axes[row, column]
            ax.imshow(image, interpolation="nearest")
            ax.set_xticks([])
            ax.set_yticks([])
            for spine in ax.spines.values():
                spine.set_linewidth(.5)
            if row == 0:
                ax.set_title(f"Frame {frames[column]}", fontsize=10)
            if column == 0:
                ax.set_ylabel(label, fontsize=11)
    fig.subplots_adjust(left=.055, right=.995, bottom=.01, top=.94, wspace=.025, hspace=.025)
    output = run / "plots"
    output.mkdir(exist_ok=True)
    stem = "sequence_grid_" + "_".join(str(frame) for frame in frames)
    for extension in ("png", "svg"):
        fig.savefig(output / f"{stem}.{extension}", dpi=200, bbox_inches="tight", pad_inches=.03)
    plt.close(fig)
    print(f"Saved {len(rows)} × {len(frames)} grid: {output / (stem + '.png')}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--frames", type=int, nargs="+", required=True, help="Zero-based animation frame indices")
    parser.add_argument("--gt-images", type=Path, help="Optional matching GT PNG sequence folder: frame_0000.png, ...")
    args = parser.parse_args()
    plot_grid(args.run.resolve(), args.frames, args.gt_images)
