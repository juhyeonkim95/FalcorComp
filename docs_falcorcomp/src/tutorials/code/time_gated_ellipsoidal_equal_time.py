"""Equal-time comparison of TimeGatedPathTracerInline's connection sampling methods (dragon Cornell box)."""
# 1. Load the scene
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import falcorcomp as falcor

SIZE = 1024
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box-dragon-diffuse/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SECONDS = 2.0                     # rendering time for each method
REFERENCE = Path("reference.npy")  # rendered below if missing
REFERENCE_SPP = 262144
TRACER = {"samplesPerPixel": 32, "maxBounces": 6,
          "timeGateMode": "box", "timeGateWindow": 0.01, "timeCenter": 17.337084148727985}
METHODS = ["direct", "ellipsoidal", "ellipsoidal_direct_mis"]


# 2. Build a render graph for a connection sampling method
def create_graph(sampling_method):
    graph = testbed.create_render_graph(sampling_method)
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserVBufferRT", {
        "samplePattern": "Center", "sampleCount": 1,
        "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
        "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
    })
    graph.create_pass("Tracer", "TimeGatedPathTracerInline",
                      {**TRACER, "samplingMethod": sampling_method})
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
    graph.add_edge("Laser.viewW", "Tracer.laserviewW")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    return graph


# 3. Render each method for the same time
def render(graph, seconds):
    testbed.render_graph = graph
    for _ in range(10):  # warm-up: shader compilation and the triangle sampler; not counted
        testbed.frame()
    graph.get_pass("Accumulate").reset()
    testbed.device.wait()
    frames, elapsed = 0, 0.0
    while elapsed < seconds:
        start = time.perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        elapsed += time.perf_counter() - start
        frames += 1
    return graph.get_output("Accumulate.output").to_numpy()[..., :3].copy(), frames


results = {}
for method in METHODS:
    results[method] = render(create_graph(method), SECONDS)

# 4. Compare with the reference: direct sampling with many more samples
if not REFERENCE.exists():
    graph = create_graph("direct")
    testbed.render_graph = graph
    for _ in range(REFERENCE_SPP // TRACER["samplesPerPixel"]):
        testbed.frame()
    np.save(REFERENCE, graph.get_output("Accumulate.output").to_numpy()[..., :3])
reference = np.load(REFERENCE)


def relative_mse(image):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


labels = []
for method, (image, frames) in results.items():
    labels.append(f"{method}\n{frames} frames, relMSE {relative_mse(image):.4f}")
    print(labels[-1].replace("\n", ": "))


# 5. Save the comparison: the full images, and a crop around the dragon's head below them
def to_display(image):
    image = np.maximum(image, 0.0)
    image = image / (1.0 + image)  # Reinhard
    image = np.where(image <= 0.0031308, 12.92 * image, 1.055 * image ** (1 / 2.4) - 0.055)  # sRGB
    return Image.fromarray((np.clip(image, 0, 1) * 255).astype(np.uint8))


images = [image for image, _ in results.values()] + [reference]
labels.append(f"Reference\n{REFERENCE_SPP} spp")
PANEL, CROP = 512, (180, 400, 500, 720)  # crop box in the 1024 x 1024 image
font = ImageFont.load_default(size=26)
comparison = Image.new("RGB", (PANEL * len(images), 72 + 2 * PANEL), "white")
draw = ImageDraw.Draw(comparison)
for index, (image, label) in enumerate(zip(images, labels)):
    display = to_display(image)
    comparison.paste(display.resize((PANEL, PANEL), Image.LANCZOS), (index * PANEL, 72))
    crop = display.crop(CROP).resize((PANEL, PANEL), Image.NEAREST)
    comparison.paste(crop, (index * PANEL, 72 + PANEL))
    draw.multiline_text((index * PANEL + 8, 6), label, fill="black", font=font)
comparison.save("time_gated_ellipsoidal_equal_time.png")
