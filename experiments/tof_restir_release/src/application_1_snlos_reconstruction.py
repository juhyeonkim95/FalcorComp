"""Application 1 reconstruction: voxel occupancy of the hidden plane from the SNLOS renders.

Per voxel, each laser position's frame (flipped up-down to the projection's v-up convention) is
sampled along the voxel's detection ellipse; the frame's pass is the fraction of samples with
nonzero radiance, and the voxel score is the squared geometric mean of the passes
(common/snlos.voxel_score, as in the prototype). Saves per method the score map (NPY/CSV), the
final reconstruction as images, and videos revealing the voxels in scan order.
"""

import argparse
import json
from pathlib import Path
import shutil
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common.io import save_csv, save_json
from common.snlos import SnlosSetup, camera_for, detection_ellipse_pixels, voxel_score

import matplotlib
matplotlib.use("Agg")
import matplotlib.animation as animation
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

METHODS = ["pt", "naive", "ours"]
SCORE_ELLIPSE_POINTS = 64
SCORE_BAND_PIXELS = 3


def load_setup(manifest):
    return SnlosSetup(**{key: tuple(value) if isinstance(value, list) else value
                         for key, value in manifest["snlos"].items()})


def reconstruct(run, method):
    """Scores (grid_res, grid_res) indexed [y, x] (NaN for unrendered voxels) and per-voxel rows."""
    manifest = json.loads((run / method / "run.json").read_text())
    if manifest.get("status") != "complete":
        raise ValueError(f"Rendering is incomplete: {run / method}")
    setup = load_setup(manifest)
    centers = setup.voxel_centers()
    scores = np.full(setup.grid_res * setup.grid_res, np.nan)
    rows = []
    for scan_index, voxel_index in enumerate(manifest["voxels"]):
        images = np.load(run / method / "frames" / f"voxel_{voxel_index:04d}.npz")["images"]
        images = images[:, ::-1, :]  # rows bottom to top: the projection's v axis points up
        camera = camera_for(setup, images.shape[2], images.shape[1])
        ellipse = detection_ellipse_pixels(setup, camera, centers[voxel_index], SCORE_ELLIPSE_POINTS)
        score, info = voxel_score(images, ellipse, band_px=SCORE_BAND_PIXELS)
        scores[voxel_index] = score
        rows.append({"scan_index": scan_index, "voxel": voxel_index, "x": voxel_index % setup.grid_res,
                     "y": voxel_index // setup.grid_res, "score": score,
                     "mean_pass": float(info["per_image_pass"].mean()),
                     "min_pass": float(info["per_image_pass"].min()),
                     "mean_snr": float(np.mean(info["per_image_snr"])), "ellipse_pixels": len(ellipse)})
    return manifest, setup, scores.reshape(setup.grid_res, setup.grid_res), rows


def display(scores):
    """Image orientation: +y (up in the scene) at the top row."""
    return np.flipud(scores)


def save_final(path_stem, scores, vmax, title=None):
    figure, axis = plt.subplots(figsize=(4.6, 4))
    shown = axis.imshow(display(scores), vmin=0.0, vmax=vmax, interpolation="nearest")
    figure.colorbar(shown, ax=axis, fraction=0.046, pad=0.04)
    axis.set_xticks([])
    axis.set_yticks([])
    if title:
        axis.set_title(title)
    figure.tight_layout()
    for extension in ("png", "svg"):
        figure.savefig(f"{path_stem}.{extension}", dpi=200)
    plt.close(figure)
    # Plain image: one pixel per voxel, upscaled without interpolation.
    colors = plt.get_cmap()(np.clip(np.nan_to_num(display(scores)) / vmax, 0.0, 1.0))[..., :3]
    plt.imsave(f"{path_stem}_raw.png", np.kron(colors, np.ones((16, 16, 1))))


def evolution_video(path, results, labels, vmax, fps):
    """Reveal voxels in scan order (red box = current voxel), one panel per method."""
    order = results[0][3]
    grid = results[0][1].grid_res
    colormap = plt.get_cmap().copy()
    colormap.set_bad(alpha=0.0)
    figure, axes = plt.subplots(1, len(results), figsize=(3.2 * len(results), 3.6), squeeze=False)
    axes = axes[0]
    shown = [np.full((grid, grid), np.nan) for _ in results]
    artists, boxes = [], []
    inset = 0.08
    for axis, label, image in zip(axes, labels, shown):
        axis.set_axis_off()
        axis.set_title(label)
        artists.append(axis.imshow(image, vmin=0.0, vmax=vmax, cmap=colormap, interpolation="nearest"))
        box = Rectangle((-0.5 + inset, -0.5 + inset), 1 - 2 * inset, 1 - 2 * inset,
                        fill=False, edgecolor="red", linewidth=2)
        axis.add_patch(box)
        boxes.append(box)
    figure.tight_layout()

    def update(frame):
        row = order[frame]
        # Display row of voxel y (flipped so +y is up), column x.
        display_row, column = grid - 1 - row["y"], row["x"]
        for image, artist, box, result in zip(shown, artists, boxes, results):
            image[display_row, column] = display(result[2])[display_row, column]
            artist.set_data(image)
            box.set_xy((column - 0.5 + inset, display_row - 0.5 + inset))
        return artists + boxes

    movie = animation.FuncAnimation(figure, update, frames=len(order), interval=1000 / fps, blit=True)
    movie.save(str(path), writer=animation.FFMpegWriter(fps=fps), dpi=150)
    plt.close(figure)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", type=Path, required=True, help="rendering output of one scene")
    parser.add_argument("--fps", type=int, default=60)
    args = parser.parse_args()
    if shutil.which("ffmpeg") is None:
        parser.error("ffmpeg is required to encode the videos")

    run = args.run.resolve()
    methods = [method for method in METHODS if (run / method / "run.json").is_file()]
    if not methods:
        parser.error(f"No rendered methods in {run}")
    output = run / "reconstruction"
    output.mkdir(parents=True, exist_ok=True)
    results, labels = [], []
    for method in methods:
        manifest, setup, scores, rows = reconstruct(run, method)
        results.append((method, setup, scores, rows))
        labels.append(f"{manifest['label']} ({manifest['spp_per_frame']} spp)")
        np.save(output / f"{method}_scores.npy", scores)
        save_csv(output / f"{method}_voxels.csv", rows)
        print(f"{method}: mean score {np.nanmean(scores):.4f}, max {np.nanmax(scores):.4f}", flush=True)
    if any(result[3] and [row["voxel"] for row in result[3]] != [row["voxel"] for row in results[0][3]]
           for result in results):
        raise ValueError("Methods rendered different voxel scans")

    # One color scale for all methods so the reconstructions are comparable.
    vmax = max(float(np.nanmax(result[2])) for result in results) or 1.0
    for (method, _, scores, _), label in zip(results, labels):
        save_final(output / f"{method}_reconstruction", scores, vmax, title=label)
    figure, axes = plt.subplots(1, len(results), figsize=(3.4 * len(results) + 0.8, 3.6), squeeze=False)
    for axis, (method, _, scores, _), label in zip(axes[0], results, labels):
        shown = axis.imshow(display(scores), vmin=0.0, vmax=vmax, interpolation="nearest")
        axis.set_title(label)
        axis.set_xticks([])
        axis.set_yticks([])
    figure.colorbar(shown, ax=list(axes[0]), fraction=0.02, pad=0.02)
    for extension in ("png", "svg"):
        figure.savefig(output / f"comparison.{extension}", dpi=200, bbox_inches="tight")
    plt.close(figure)

    evolution_video(output / "evolution_comparison.mp4", results, labels, vmax, args.fps)
    for result, label in zip(results, labels):
        evolution_video(output / f"{result[0]}_evolution.mp4", [result], [label], vmax, args.fps)
    save_json(output / "reconstruction.json", {
        "methods": methods, "color_scale_max": vmax, "score": "squared geometric mean over laser positions of the "
        "fraction of nonzero detection-ellipse samples", "ellipse_points": SCORE_ELLIPSE_POINTS,
        "band_pixels": SCORE_BAND_PIXELS, "display": "row 0 = +y (top), column = x"})
    print(f"Saved {output}", flush=True)


if __name__ == "__main__":
    main()
