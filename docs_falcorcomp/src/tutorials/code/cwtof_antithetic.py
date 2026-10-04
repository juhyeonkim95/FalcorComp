"""Equal-time comparison of naive and antithetic CW-ToF rendering at three modulation wavelengths."""
# 1. Load the scene
import time

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SECONDS = 0.3              # rendering time for each method
REFERENCE_FRAMES = 16384   # 16384 frames x 16 spp for each reference
WAVELENGTHS = [0.02, 0.1, 1.0]

# 2. Build the render graph
CWTOF = {
    "samplesPerPixel": 1, "maxBounces": 4,
    "computeDirect": False,  # indirect light only
    "waveform": "cos",
    "useSingleChannel": True, "singleChannel": "luminance",
}
NAIVE = {"useAntitheticSampling": False}
# The antithetic vertex is found by Newton's method on the triangle's barycentric
# coordinates, moving along the average path-length gradient.
ANTITHETIC = {"useAntitheticSampling": True,
              "shiftmapMethod": "barycentric", "gaugeMode": "avg_grad"}


def create_graph(properties):
    graph = testbed.create_render_graph("CWToF")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Light", "LaserLight", {
        "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
    })
    graph.create_pass("Tracer", "CWToFPathTracerInline", {**CWTOF, **properties})
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Light", "Tracer")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    return graph


# 3. Render each method for the same time
def render(graph, seconds=None, frames=None):
    testbed.render_graph = graph
    testbed.frame()  # compiles the shaders
    start = time.perf_counter()
    while time.perf_counter() - start < 1.0:  # warm up the GPU
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
    return graph.get_output("Accumulate.output").to_numpy()[..., 0], count


def relative_mse(image, reference):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


# 4. Compare with a reference at each wavelength
rows = []
for wavelength in WAVELENGTHS:
    reference, _ = render(create_graph({**NAIVE, "modulationWavelength": wavelength,
                                        "samplesPerPixel": 16}), frames=REFERENCE_FRAMES)
    results = []
    for name, method in [("Naive", NAIVE), ("Antithetic", ANTITHETIC)]:
        image, spp = render(create_graph({**method, "modulationWavelength": wavelength}),
                            seconds=SECONDS)
        error = relative_mse(image, reference)
        print(f"wavelength {wavelength}: {name}, {spp} spp, relMSE {error:.4f}")
        results.append((f"{name}: {spp} spp\nrelMSE {error:.3g}", image))
    rows.append((wavelength, results + [("Reference", reference)]))

# 5. Show the images with a diverging colormap, 0 in white
fig, axes = plt.subplots(len(rows), 3, figsize=(9, 3.2 * len(rows)))
for row, (wavelength, images) in zip(axes, rows):
    limit = np.percentile(np.abs(images[-1][1]), 99)
    for ax, (label, image) in zip(row, images):
        ax.imshow(image, cmap="bwr", vmin=-limit, vmax=limit)
        ax.set_title(label, fontsize=10)
        ax.set_xticks([])
        ax.set_yticks([])
    row[0].set_ylabel(f"$\\lambda$ = {wavelength}", fontsize=12)
fig.tight_layout()
fig.savefig("cwtof_antithetic.png", dpi=100)
