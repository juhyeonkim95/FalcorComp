"""Application 1 rendering plots: rendered frames with the detection ellipse, as images and videos.

For each voxel (in scan order), the displayed frame is one laser position (or the mean over all)
with the voxel's detection ellipse painted in red: a filled voxel lights up the wall along it.
Writes per-method overlays, a PT | naive | ours comparison per voxel, a figure of selected
voxels, and MP4 videos of the scan (per method and side by side).
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.snlos import SnlosSetup, camera_for, detection_ellipse_pixels, paint_points, tone_map_display

import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt

METHODS = ["pt", "naive", "ours"]


def load_run(run, method):
    manifest = json.loads((run / method / "run.json").read_text())
    if manifest.get("status") != "complete":
        raise ValueError(f"Rendering is incomplete: {run / method}")
    return manifest


def overlay(images, setup, voxel, display_sample, scale):
    """Displayed frame (camera orientation, top row up) with the detection ellipse in red."""
    image = images.mean(axis=0) if display_sample == "mean" else images[int(display_sample)]
    height, width = image.shape
    camera = camera_for(setup, width, height)
    # The projection's v axis points up, so paint on the up-down flipped frame and flip back.
    painted = paint_points(tone_map_display(np.flipud(image), scale), detection_ellipse_pixels(setup, camera, voxel, 256))
    return np.flipud(painted)


def to_uint8(rgb):
    return (np.clip(rgb, 0.0, 1.0) * 255).astype(np.uint8)


def labeled_row(tiles, labels, footer):
    """Side-by-side tiles with a label above each and a footer line (even dimensions for H.264)."""
    height, width = tiles[0].shape[:2]
    header, bottom = 22, 20
    canvas = Image.new("RGB", (width * len(tiles), height + header + bottom), "black")
    draw = ImageDraw.Draw(canvas)
    for index, (tile, label) in enumerate(zip(tiles, labels)):
        canvas.paste(Image.fromarray(tile), (index * width, header))
        draw.text((index * width + 6, 5), label, fill="white")
    draw.text((6, height + header + 4), footer, fill="white")
    return canvas.crop((0, 0, canvas.width - canvas.width % 2, canvas.height - canvas.height % 2))


def encode_video(ffmpeg, frame_dir, output, fps):
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-framerate", str(fps),
                    "-i", str(frame_dir / "frame_%05d.png"), "-c:v", "libx264", "-crf", "18",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(output)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", type=Path, required=True, help="rendering output of one scene")
    parser.add_argument("--display-sample", default="6", help="laser position index to show, or 'mean'")
    parser.add_argument("--display-scale", type=float, default=100.0, help="radiance scale before tone mapping")
    parser.add_argument("--figure-voxels", type=int, nargs="+", default=[162, 312, 462],
                        help="voxel indices shown in the summary figure")
    parser.add_argument("--fps", type=int, default=60)
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        parser.error("ffmpeg is required to encode the videos")

    run = args.run.resolve()
    methods = [method for method in METHODS if (run / method / "run.json").is_file()]
    manifests = {method: load_run(run, method) for method in methods}
    reference = manifests[methods[0]]
    setup = SnlosSetup(**{key: tuple(value) if isinstance(value, list) else value
                          for key, value in reference["snlos"].items()})
    voxels = reference["voxels"]
    if any(manifest["voxels"] != voxels for manifest in manifests.values()):
        raise ValueError("Methods rendered different voxel scans")
    centers = setup.voxel_centers()
    labels = [f"{manifests[m]['label']} ({manifests[m]['spp_per_frame']} spp)" for m in methods]
    plots = run / "plots_rendering"
    figure_tiles = {}

    with tempfile.TemporaryDirectory() as temporary:
        frame_dirs = {name: Path(temporary) / name for name in methods + ["comparison"]}
        for directory in frame_dirs.values():
            directory.mkdir()
        for method in methods:
            (plots / "overlays" / method).mkdir(parents=True, exist_ok=True)
        for frame, voxel_index in enumerate(voxels):
            voxel = centers[voxel_index]
            tiles = []
            for method in methods:
                data = np.load(run / method / "frames" / f"voxel_{voxel_index:04d}.npz")
                tile = to_uint8(overlay(data["images"], setup, voxel, args.display_sample, args.display_scale))
                tiles.append(tile)
                Image.fromarray(tile).save(plots / "overlays" / method / f"voxel_{voxel_index:04d}.png")
                Image.fromarray(tile).save(frame_dirs[method] / f"frame_{frame:05d}.png")
            gate = float(np.load(run / methods[0] / "frames" / f"voxel_{voxel_index:04d}.npz")["gate_center"])
            footer = (f"voxel {voxel_index} (x {voxel_index % setup.grid_res}, y {voxel_index // setup.grid_res})"
                      f"  gate {gate:.3f}  scan {frame + 1}/{len(voxels)}")
            labeled_row(tiles, labels, footer).save(frame_dirs["comparison"] / f"frame_{frame:05d}.png")
            if voxel_index in args.figure_voxels:
                figure_tiles[voxel_index] = tiles
            if (frame + 1) % 100 == 0 or frame + 1 == len(voxels):
                print(f"overlays: {frame + 1}/{len(voxels)} voxels", flush=True)
        for name, directory in frame_dirs.items():
            encode_video(ffmpeg, directory, plots / f"{name}.mp4", args.fps)

    # Summary figure: selected voxels (rows) x methods (columns).
    rows = [voxel for voxel in args.figure_voxels if voxel in figure_tiles]
    if rows:
        figure, axes = plt.subplots(len(rows), len(methods), figsize=(3 * len(methods), 3 * len(rows)), squeeze=False)
        for row, voxel_index in enumerate(rows):
            for column, method in enumerate(methods):
                axes[row, column].imshow(figure_tiles[voxel_index][column])
                axes[row, column].set_xticks([])
                axes[row, column].set_yticks([])
                if row == 0:
                    axes[row, column].set_title(labels[column])
            axes[row, 0].set_ylabel(f"voxel {voxel_index}")
        figure.tight_layout()
        for extension in ("png", "svg"):
            figure.savefig(plots / f"selected_voxels.{extension}", dpi=200)
        plt.close(figure)
    print(f"Saved {plots}", flush=True)


if __name__ == "__main__":
    main()
