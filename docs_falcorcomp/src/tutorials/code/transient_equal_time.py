"""Equal-time comparison of TransientHistogramPathTracerInline and TransientHistogramReSTIRInline."""
# 1. Load the scene
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(256, 256)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SECONDS = 1.0            # rendering time for each method
REFERENCE_FRAMES = 4096  # 4096 frames x 16 spp for the reference
T_MIN, T_MAX, BINS = 16.75, 18.03, 64
HISTOGRAM = {"timeMin": T_MIN, "timeMax": T_MAX, "timeBin": BINS, "histogramFilter": "box"}
PT = {"samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False, **HISTOGRAM}
RESTIR = {**PT,
          "spatialReuseIteration": 3, "spatialReuseNeighborCount": 5,
          "spatialReuseGatherRadius": 10.0, "useTemporalReuse": False,
          "shiftMappingMethod": "local_tangent", "gaugeMode": "avg_grad",
          "reconnectionRoughnessThreshold": 0.05}
# The same with temporal reuse and one spatial round: each frame also resamples the previous one.
RESTIR_TEMPORAL = {**RESTIR, "spatialReuseIteration": 1, "useTemporalReuse": True}


# 2. Build a render graph around a tracer
def create_graph(tracer, properties):
    graph = testbed.create_render_graph(tracer)
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserLight", {
        "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
        "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
    })
    graph.create_pass("Tracer", tracer, properties)
    graph.create_pass("Accumulate", "TransientHistogramAccumulatePass", {})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser", "Tracer")
    graph.add_edge("Tracer.histogram", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    return graph


# 3. Render each tracer for the same time
def render(graph, seconds=None, frames=None):
    testbed.render_graph = graph
    for _ in range(10):  # warm-up frames compile the shaders; they are not counted
        testbed.frame()
    graph.get_pass("Accumulate").reset()
    testbed.device.wait()
    count, elapsed = 0, 0.0
    while (elapsed < seconds) if seconds is not None else (count < frames):
        start = time.perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        elapsed += time.perf_counter() - start
        count += 1
    histogram = graph.get_output("Accumulate.output").to_numpy()[..., :3]  # (bins, height, width, RGB)
    return histogram, count, elapsed


pt_graph = create_graph("TransientHistogramPathTracerInline", PT)
pt_histogram, pt_frames, pt_time = render(pt_graph, seconds=SECONDS)
restir_graph = create_graph("TransientHistogramReSTIRInline", RESTIR)
restir_histogram, restir_frames, restir_time = render(restir_graph, seconds=SECONDS)
temporal_graph = create_graph("TransientHistogramReSTIRInline", RESTIR_TEMPORAL)
temporal_histogram, temporal_frames, temporal_time = render(temporal_graph, seconds=SECONDS)

# 4. Render a reference with many more path-tracing samples
reference_graph = create_graph("TransientHistogramPathTracerInline", PT)
reference, _, _ = render(reference_graph, frames=REFERENCE_FRAMES)


# 5. Compare over all bins
def relative_mse(histogram):
    return float(np.mean((histogram - reference) ** 2) / np.mean(reference ** 2))


def mape(histogram):  # mean absolute error relative to each texel (plus 1 % of the mean)
    return float(np.mean(np.abs(histogram - reference) / (0.01 * np.mean(reference) + reference)))


def to_display(image):
    image = np.maximum(image, 0.0)
    return (np.clip((image / (1.0 + image)) ** (1 / 2.2), 0, 1) * 255).astype(np.uint8)


SHOWN_BINS = [8, 20, 32, 44]  # a row of bins per method
results = [
    (f"THPT: {pt_frames} frames", pt_histogram),
    (f"TH ReSTIR, spatial: {restir_frames} frames", restir_histogram),
    (f"TH ReSTIR, temporal + spatial: {temporal_frames} frames", temporal_histogram),
]
results = [(f"{label}, relMSE {relative_mse(h):.4f}, MAPE {mape(h):.3f}", h) for label, h in results]
results.append((f"Reference: {REFERENCE_FRAMES * PT['samplesPerPixel']} spp", reference))
for label, _ in results:
    print(label)
print(f"Rendering time: THPT {pt_time:.2f} s, TH ReSTIR {restir_time:.2f} s and {temporal_time:.2f} s")

height, width = reference.shape[1:3]
font = ImageFont.load_default(size=18)
comparison = Image.new("RGB", (width * len(SHOWN_BINS), len(results) * (height + 32)), "white")
draw = ImageDraw.Draw(comparison)
for row, (label, histogram) in enumerate(results):
    top = row * (height + 32)
    draw.text((8, top + 6), label, fill="black", font=font)
    for column, b in enumerate(SHOWN_BINS):
        tile = histogram[b] * (T_MAX - T_MIN)  # as bright as the image if all light arrived in the bin
        comparison.paste(Image.fromarray(to_display(tile)), (column * width, top + 32))
comparison.save("transient_equal_time.png")
