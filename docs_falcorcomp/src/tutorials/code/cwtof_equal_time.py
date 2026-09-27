"""Equal-time comparison of naive and antithetic sampling in CWToFPathTracerInline on the Cornell box."""
# 1. Load the scene
import time

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(256, 256)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SECONDS = 0.3              # rendering time for each method
REFERENCE_FRAMES = 32768   # 32768 frames x 8 spp for the reference
TRACER = {"samplesPerPixel": 8, "maxBounces": 3, "computeDirect": False,
          "waveform": "cos", "modulationWavelength": 0.01,
          "useSingleChannel": True, "singleChannel": "luminance"}


# 2. Build a render graph around the tracer
def create_graph(properties):
    graph = testbed.create_render_graph("CWToF")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Light", "LaserVBufferRT", {
        "samplePattern": "Center", "sampleCount": 1,
        "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
    })
    graph.create_pass("Tracer", "CWToFPathTracerInline", properties)
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Light.vbuffer", "Tracer.laservbuffer")
    graph.add_edge("Light.viewW", "Tracer.laserviewW")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    return graph


# 3. Render each method for the same time
def render(graph, seconds=None, frames=None):
    testbed.render_graph = graph
    testbed.frame()  # the first frame compiles the shaders
    # Warm up for a second, so the GPU runs at full speed; these frames are not counted.
    start = time.perf_counter()
    while time.perf_counter() - start < 1.0:
        testbed.frame()
        testbed.device.wait()
    graph.get_pass("Accumulate").reset()
    testbed.device.wait()
    count, elapsed = 0, 0.0
    while (elapsed < seconds) if seconds is not None else (count < frames):
        start = time.perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        elapsed += time.perf_counter() - start
        count += 1
    return graph.get_output("Accumulate.output").to_numpy()[..., 0], count


naive, naive_frames = render(create_graph({**TRACER, "useAntitheticSampling": False}), seconds=SECONDS)
antithetic, antithetic_frames = render(create_graph({**TRACER, "useAntitheticSampling": True}), seconds=SECONDS)

# 4. Render a reference with many more naive samples
reference, _ = render(create_graph({**TRACER, "useAntitheticSampling": False}), frames=REFERENCE_FRAMES)


# 5. Compare
def relative_mse(image):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


spp = TRACER["samplesPerPixel"]
results = [
    (f"Naive: {naive_frames * spp} spp, relMSE {relative_mse(naive):.4f}", naive),
    (f"Antithetic: {antithetic_frames * spp} spp, relMSE {relative_mse(antithetic):.4f}", antithetic),
    (f"Reference: {REFERENCE_FRAMES * spp} spp", reference),
]
for label, _ in results:
    print(label)

limit = np.percentile(np.abs(reference), 95)
figure, axes = plt.subplots(1, 3, figsize=(12, 4.4))
for axis, (label, image) in zip(axes, results):
    axis.imshow(image, cmap="bwr", vmin=-limit, vmax=limit)
    axis.set_title(label, fontsize=11)
    axis.axis("off")
figure.tight_layout()
figure.savefig("cwtof_equal_time.png", dpi=110)
