"""Equal-time comparison of TimeGatedPathTracerInline and TimeGatedReSTIRInline on the Cornell box."""
# 1. Load the scene
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SECONDS = 1.0            # rendering time for each method
REFERENCE_FRAMES = 4096  # 4096 frames x 16 spp for the reference
GATE = {"timeGateMode": "box", "timeGateWindow": 0.02, "timeCenter": 17.337}
PT = {"samplesPerPixel": 16, "maxBounces": 6, **GATE}
RESTIR = {**PT,
          "spatialReuseIteration": 3, "spatialReuseNeighborCount": 5,
          "spatialReuseGatherRadius": 10.0, "useTemporalReuse": False,
          "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
          "specularRoughnessThreshold": 0.05}


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
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
    graph.add_edge("Laser.viewW", "Tracer.laserviewW")
    graph.add_edge("Tracer.color", "Accumulate.input")
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
    image = graph.get_output("Accumulate.output").to_numpy()[..., :3]
    return image, count, elapsed


pt_graph = create_graph("TimeGatedPathTracerInline", PT)
pt_image, pt_frames, pt_time = render(pt_graph, seconds=SECONDS)
restir_graph = create_graph("TimeGatedReSTIRInline", RESTIR)
restir_image, restir_frames, restir_time = render(restir_graph, seconds=SECONDS)

# 4. Render a reference with many more path-tracing samples
reference_graph = create_graph("TimeGatedPathTracerInline", PT)
reference, _, _ = render(reference_graph, frames=REFERENCE_FRAMES)


# 5. Compare
def relative_mse(image):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


def to_display(image, exposure=1.0):
    image = np.maximum(image, 0.0) * exposure
    return (np.clip((image / (1.0 + image)) ** (1 / 2.2), 0, 1) * 255).astype(np.uint8)


results = [
    (f"TGPT: {pt_frames} frames, relMSE {relative_mse(pt_image):.4f}", pt_image),
    (f"TG ReSTIR: {restir_frames} frames, relMSE {relative_mse(restir_image):.4f}", restir_image),
    (f"Reference: {REFERENCE_FRAMES * PT['samplesPerPixel']} spp", reference),
]
for label, _ in results:
    print(label)
print(f"Rendering time: TGPT {pt_time:.2f} s, TG ReSTIR {restir_time:.2f} s")

panels = [Image.fromarray(to_display(image)) for _, image in results]
width, height = panels[0].size
comparison = Image.new("RGB", (width * len(panels), height + 32), "white")
draw = ImageDraw.Draw(comparison)
font = ImageFont.load_default(size=18)
for index, (panel, (label, _)) in enumerate(zip(panels, results)):
    comparison.paste(panel, (index * width, 32))
    draw.text((index * width + 8, 6), label, fill="black", font=font)
comparison.save("time_gated_equal_time.png")
