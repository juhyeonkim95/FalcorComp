"""Online time-gated rendering with a moving gate: TGPT and TG ReSTIR at equal frame time."""
# 1. Load the scene
import csv
from pathlib import Path
import shutil
import subprocess
import tempfile
from time import perf_counter

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import falcorcomp as falcor

SIZE = 1024
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The gate moves from 16.75 to 17.331 over 100 frames, one frame per gate center.
FRAMES = 100
GATE_CENTERS = np.linspace(16.75, 17.331213307240706, FRAMES)
GATE = {"timeGateMode": "box", "timeGateWindow": 0.01, "timeCenter": float(GATE_CENTERS[0])}
PT = {"samplesPerPixel": 32, "maxBounces": 6, **GATE}
RESTIR = {**PT,
          "spatialReuseIteration": 1, "spatialReuseNeighborCount": 3,
          "useTemporalReuse": True, "temporalHistoryLength": 10.0, "isSceneDynamic": False,
          "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
          "specularRoughnessThreshold": 0.05}
SKIP_FRAMES = 10          # frames left out of the timing: shader compilation, history warm-up
TOLERANCE = 0.05          # accepted frame-time difference between the two tracers
REFERENCE = Path("reference")  # frame_0000.npy ... frame_0099.npy; rendered below if missing
REFERENCE_SPP = 32768


# 2. Build a render graph around a tracer
def create_graph(tracer, properties):
    graph = testbed.create_render_graph(tracer)
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserVBufferRT", {
        "samplePattern": "Center", "sampleCount": 1,
        "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
        "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
    })
    graph.create_pass("Tracer", tracer, properties)
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
    graph.add_edge("Laser.viewW", "Tracer.laserviewW")
    graph.mark_output("Tracer.color")  # one frame per gate: no accumulation
    return graph


# 3. Render the sequence: one frame per gate center
def render_sequence(tracer, properties, on_frame=None):
    """Returns the mean frame time in ms. on_frame(frame, image) receives each frame's image;
    images are read back only when it is given, so timing runs have no readback."""
    graph = create_graph(tracer, properties)  # a new graph starts with an empty ReSTIR history
    testbed.render_graph = graph
    tracer_pass = graph.get_pass("Tracer")
    times = []
    for frame, center in enumerate(GATE_CENTERS):
        # Moving the gate keeps ReSTIR's history, which temporal reuse shifts to the new gate.
        tracer_pass.set_time_gate_info(float(center), float(center), 1)
        start = perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        times.append(perf_counter() - start)
        if on_frame is not None:
            on_frame(frame, graph.get_output("Tracer.color").to_numpy()[..., :3])
    return 1000.0 * float(np.mean(times[SKIP_FRAMES:]))


# 4. Match the frame time: ReSTIR keeps 32 spp, the path tracer's spp is adjusted
restir_ms = render_sequence("TimeGatedReSTIRInline", RESTIR)
print(f"TG ReSTIR: {RESTIR['samplesPerPixel']} spp, {restir_ms:.1f} ms/frame")
trials = {}
pt_spp = PT["samplesPerPixel"]
for attempt in range(4):  # the equal-spp run, then up to three adjustments
    trials[pt_spp] = render_sequence("TimeGatedPathTracerInline", {**PT, "samplesPerPixel": pt_spp})
    print(f"TGPT: {pt_spp} spp, {trials[pt_spp]:.1f} ms/frame")
    if abs(trials[pt_spp] / restir_ms - 1.0) <= TOLERANCE:
        break
    pt_spp = max(1, round(pt_spp * restir_ms / trials[pt_spp]))
    if pt_spp in trials:
        break
pt_spp = min(trials, key=lambda spp: abs(trials[spp] - restir_ms))
pt_ms = trials[pt_spp]

# 5. Render both sequences and compare every frame with the reference
if not REFERENCE.exists():
    print(f"Rendering the reference with TGPT at {REFERENCE_SPP} spp per frame (slow)")
    REFERENCE.mkdir()
    def save_reference(frame, image):
        np.save(REFERENCE / f"frame_{frame:04d}.npy", image)

    render_sequence("TimeGatedPathTracerInline", {**PT, "samplesPerPixel": REFERENCE_SPP},
                    on_frame=save_reference)


def relative_mse(image, reference):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


def to_display(image):
    image = np.maximum(image, 0.0)
    image = image / (1.0 + image)  # Reinhard
    image = np.where(image <= 0.0031308, 12.92 * image, 1.055 * image ** (1 / 2.4) - 0.055)  # sRGB
    return (np.clip(image, 0, 1) * 255).astype(np.uint8)


def record(tracer, properties):
    """Renders the sequence and returns each frame's display image and relMSE."""
    frames, errors = [], []

    def on_frame(frame, image):
        errors.append(relative_mse(image, np.load(REFERENCE / f"frame_{frame:04d}.npy")))
        frames.append(to_display(image))

    render_sequence(tracer, properties, on_frame)
    return frames, errors


pt_frames, pt_errors = record("TimeGatedPathTracerInline", {**PT, "samplesPerPixel": pt_spp})
restir_frames, restir_errors = record("TimeGatedReSTIRInline", RESTIR)
print(f"Mean relMSE: TGPT {np.mean(pt_errors):.3f}, TG ReSTIR {np.mean(restir_errors):.3f}")
with open("errors.csv", "w", newline="") as file:
    writer = csv.writer(file)
    writer.writerow(["frame", "gate_center", "tgpt_relmse", "tg_restir_relmse"])
    writer.writerows(zip(range(FRAMES), GATE_CENTERS, pt_errors, restir_errors))


# 6. Save a video per tracer, with the frame time and each frame's error
def save_video(path, name, spp, frame_ms, frames, errors, fps=15):
    font = ImageFont.load_default(size=28)
    with tempfile.TemporaryDirectory() as folder:
        for frame, (image, error) in enumerate(zip(frames, errors)):
            canvas = Image.new("RGB", (SIZE, SIZE + 80), "black")
            canvas.paste(Image.fromarray(image), (0, 80))
            draw = ImageDraw.Draw(canvas)
            title = f"{name}: {spp} spp, {frame_ms:.1f} ms/frame"
            draw.text((16, 6), title, fill="white", font=font)
            draw.text((16, 42), f"frame {frame:3d}   gate {GATE_CENTERS[frame]:.3f}   "
                                f"relMSE {error:.3f}", fill="white", font=font)
            canvas.save(f"{folder}/frame_{frame:04d}.png")
        subprocess.run([shutil.which("ffmpeg"), "-y", "-loglevel", "error", "-framerate", str(fps),
                        "-i", f"{folder}/frame_%04d.png", "-c:v", "libx264", "-crf", "20",
                        "-pix_fmt", "yuv420p", path], check=True)


save_video("time_gated_tgpt_online.mp4", "TGPT", pt_spp, pt_ms, pt_frames, pt_errors)
save_video("time_gated_restir_online.mp4", "TG ReSTIR", RESTIR["samplesPerPixel"], restir_ms,
           restir_frames, restir_errors)
