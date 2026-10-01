"""Online transient rendering with a moving camera: THPT and TH ReSTIR at equal frame time.

Usage: python transient_restir_online.py [cornell-box | veach-ajar]
"""
# 1. Load the scene
import csv
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from time import perf_counter

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import falcorcomp as falcor

# Each scene: its file, image size, histogram range and laser (in Veach, Ajar, at the starting camera).
SCENES = {
    "cornell-box": {
        "file": "cornell-box/scene-v4-nolight.pbrt", "size": (256, 256), "range": (16.75, 18.03),
        "laser": {"laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
                  "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0},
    },
    "veach-ajar": {
        "file": "veach-ajar/scene-v4.pbrt", "size": (480, 270), "range": (19.0, 21.0),
        "laser": {"laserPosition": [4.054023, 1.616475, -2.306524],
                  "laserDirection": [-0.990015, -0.032298, -0.137213],
                  "laserPower": [1000.0, 1000.0, 1000.0], "laserAngle": 0.0},
    },
}
SCENE = sys.argv[1] if len(sys.argv) > 1 else "cornell-box"
WIDTH, HEIGHT = SCENES[SCENE]["size"]
LASER = SCENES[SCENE]["laser"]

testbed = falcor.Testbed(create_window=False)
testbed.load_scene(SCENES[SCENE]["file"])
testbed.resize_frame_buffer(WIDTH, HEIGHT)
camera = testbed.scene.camera
camera.aspectRatio = WIDTH / HEIGHT
camera.apertureRadius = 0.0  # no depth of field
testbed.clock.pause()

# The camera moves forward along its view direction by STEP per frame.
FRAMES, STEP = 100, 0.005
START_POSITION = np.array([camera.position.x, camera.position.y, camera.position.z])
START_TARGET = np.array([camera.target.x, camera.target.y, camera.target.z])
FORWARD = (START_TARGET - START_POSITION) / np.linalg.norm(START_TARGET - START_POSITION)

(T_MIN, T_MAX), BINS = SCENES[SCENE]["range"], 64
HISTOGRAM = {"timeMin": T_MIN, "timeMax": T_MAX, "timeBin": BINS, "histogramFilter": "box"}
PT = {"samplesPerPixel": 32, "maxBounces": 6, "computeDirect": False, "useAlphaTest": True, **HISTOGRAM}
RESTIR = {**PT,
          "spatialReuseIteration": 1, "spatialReuseNeighborCount": 5,
          "useTemporalReuse": True, "temporalHistoryLength": 20.0,
          "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
          "reconnectionRoughnessThreshold": 0.05}
SKIP_FRAMES = 10          # frames left out of the timing: shader compilation, history warm-up
TOLERANCE = 0.05          # accepted frame-time difference between the two tracers
REFERENCE = Path(f"reference-{SCENE}")      # frame_0009.npy, frame_0019.npy, ...; rendered below if missing
REFERENCE_FRAMES = range(9, FRAMES, 10)     # every 10th frame is compared with a reference
REFERENCE_SPP, REFERENCE_PASSES = 1024, 16  # 16 x 1024 = 16384 spp per reference frame
SHOWN_BINS = [12, 24, 36, 48]               # the bins in the videos


def set_pose(frame):
    offset = FORWARD * STEP * frame
    camera.position = falcor.float3(*(START_POSITION + offset).tolist())
    camera.target = falcor.float3(*(START_TARGET + offset).tolist())


# 2. Build a render graph around a tracer
def create_graph(tracer, properties):
    graph = testbed.create_render_graph(tracer)
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True})
    graph.create_pass("Laser", "LaserLight", LASER)
    graph.create_pass("Tracer", tracer, properties)
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser", "Tracer")
    if tracer == "TransientHistogramReSTIRInline":
        graph.add_edge("VBuffer.mvec", "Tracer.mvec")  # reprojects the history as the camera moves
    graph.mark_output("Tracer.histogram")  # one histogram per frame: no accumulation
    return graph


def read_histogram(graph):
    return graph.get_output("Tracer.histogram").to_numpy()[..., :3]  # (bins, height, width, RGB)


# 3. Render the sequence: one frame per camera pose
def render_sequence(tracer, properties, on_frame=None):
    """Returns the mean frame time in ms. on_frame(frame, histogram) receives each frame's
    histogram; it is read back only when on_frame is given, so timing runs have no readback."""
    graph = create_graph(tracer, properties)  # a new graph starts with an empty ReSTIR history
    testbed.render_graph = graph
    times = []
    for frame in range(FRAMES):
        set_pose(frame)
        start = perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        times.append(perf_counter() - start)
        if on_frame is not None:
            on_frame(frame, read_histogram(graph))
    return 1000.0 * float(np.mean(times[SKIP_FRAMES:]))


# 4. Match the frame time: ReSTIR keeps 32 spp, the path tracer's spp is adjusted
restir_ms = render_sequence("TransientHistogramReSTIRInline", RESTIR)
print(f"TH ReSTIR: {RESTIR['samplesPerPixel']} spp, {restir_ms:.1f} ms/frame")
trials = {}
pt_spp = PT["samplesPerPixel"]
for attempt in range(4):  # the equal-spp run, then up to three adjustments
    trials[pt_spp] = render_sequence("TransientHistogramPathTracerInline", {**PT, "samplesPerPixel": pt_spp})
    print(f"THPT: {pt_spp} spp, {trials[pt_spp]:.1f} ms/frame")
    if abs(trials[pt_spp] / restir_ms - 1.0) <= TOLERANCE:
        break
    pt_spp = max(1, round(pt_spp * restir_ms / trials[pt_spp]))
    if pt_spp in trials:
        break
pt_spp = min(trials, key=lambda spp: abs(trials[spp] - restir_ms))
pt_ms = trials[pt_spp]

# 5. Render both sequences and compare every 10th frame with the reference
if not REFERENCE.exists():
    print(f"Rendering the reference with THPT at {REFERENCE_SPP * REFERENCE_PASSES} spp per frame")
    REFERENCE.mkdir()
    graph = create_graph("TransientHistogramPathTracerInline", {**PT, "samplesPerPixel": REFERENCE_SPP})
    testbed.render_graph = graph
    for frame in REFERENCE_FRAMES:
        set_pose(frame)
        total = 0.0
        for _ in range(REFERENCE_PASSES):  # several frames, so that no single frame runs too long
            testbed.frame()
            total = total + read_histogram(graph)
        np.save(REFERENCE / f"frame_{frame:04d}.npy", (total / REFERENCE_PASSES).astype(np.float16))


def errors(histogram, reference):
    relative_mse = np.mean((histogram - reference) ** 2) / np.mean(reference ** 2)
    mape = np.mean(np.abs(histogram - reference) / (0.01 * np.mean(reference) + reference))
    return float(relative_mse), float(mape)


def to_display(histogram):
    """The shown bins in a 2 x 2 grid, each as bright as the image if all light arrived in it."""
    tiles = np.maximum(histogram[SHOWN_BINS], 0.0) * (T_MAX - T_MIN)
    tiles = tiles / (1.0 + tiles)  # Reinhard
    tiles = np.where(tiles <= 0.0031308, 12.92 * tiles, 1.055 * tiles ** (1 / 2.4) - 0.055)  # sRGB
    grid = tiles.reshape(2, 2, HEIGHT, WIDTH, 3).transpose(0, 2, 1, 3, 4).reshape(2 * HEIGHT, 2 * WIDTH, 3)
    return (np.clip(grid, 0, 1) * 255).astype(np.uint8)


def record(tracer, properties):
    """Renders the sequence and returns each frame's display image and the reference frames' errors."""
    frames, frame_errors = [], {}

    def on_frame(frame, histogram):
        if frame in REFERENCE_FRAMES:
            reference = np.load(REFERENCE / f"frame_{frame:04d}.npy").astype(np.float32)
            frame_errors[frame] = errors(histogram, reference)
        frames.append(to_display(histogram))

    render_sequence(tracer, properties, on_frame)
    return frames, frame_errors


pt_frames, pt_errors = record("TransientHistogramPathTracerInline", {**PT, "samplesPerPixel": pt_spp})
restir_frames, restir_errors = record("TransientHistogramReSTIRInline", RESTIR)
pt_mean = np.mean(list(pt_errors.values()), axis=0)
restir_mean = np.mean(list(restir_errors.values()), axis=0)
print(f"Mean relMSE: THPT {pt_mean[0]:.3f}, TH ReSTIR {restir_mean[0]:.3f}")
print(f"Mean MAPE: THPT {pt_mean[1]:.3f}, TH ReSTIR {restir_mean[1]:.3f}")
with open(f"errors-{SCENE}.csv", "w", newline="") as file:
    writer = csv.writer(file)
    writer.writerow(["frame", "thpt_relmse", "thpt_mape", "th_restir_relmse", "th_restir_mape"])
    for frame in REFERENCE_FRAMES:
        writer.writerow([frame, *pt_errors[frame], *restir_errors[frame]])


# 6. Save a video per tracer, with the frame time and the mean errors
def save_video(path, name, spp, frame_ms, frames, mean_errors, fps=15):
    font = ImageFont.load_default(size=20)
    with tempfile.TemporaryDirectory() as folder:
        for frame, image in enumerate(frames):
            canvas = Image.new("RGB", (2 * WIDTH, 2 * HEIGHT + 64), "black")
            canvas.paste(Image.fromarray(image), (0, 64))
            draw = ImageDraw.Draw(canvas)
            draw.text((10, 6), f"{name}: {spp} spp, {frame_ms:.1f} ms/frame", fill="white", font=font)
            draw.text((10, 34), f"frame {frame:3d}   mean relMSE {mean_errors[0]:.3f}   "
                                f"MAPE {mean_errors[1]:.3f}", fill="white", font=font)
            canvas.save(f"{folder}/frame_{frame:04d}.png")
        subprocess.run([shutil.which("ffmpeg"), "-y", "-loglevel", "error", "-framerate", str(fps),
                        "-i", f"{folder}/frame_%04d.png", "-c:v", "libx264", "-crf", "20",
                        "-pix_fmt", "yuv420p", path], check=True)


save_video(f"transient_thpt_online_{SCENE}.mp4", "THPT", pt_spp, pt_ms, pt_frames, pt_mean)
save_video(f"transient_restir_online_{SCENE}.mp4", "TH ReSTIR", RESTIR["samplesPerPixel"], restir_ms,
           restir_frames, restir_mean)
