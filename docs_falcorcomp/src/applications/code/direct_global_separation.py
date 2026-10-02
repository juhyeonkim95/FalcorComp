"""Separation of the direct and global (indirect) light with high-frequency checkerboards
(Nayar et al. 2006), with naive and antithetic sampling."""
# 1. Load the scene
import time

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box-separation/scene-v4.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SHIFTS = 25                # checkerboards shifted by fifths of a cell, 5 x 5
SECONDS = 0.4              # rendering time of each checkerboard image (equal time)
CONVERGED_FRAMES = 1024    # 1024 frames x 16 spp for the white image

# 2. Build the render graph
STRUCTURED_LIGHT = {
    "samplesPerPixel": 1, "maxBounces": 6,
    "computeDirect": True,  # the full measurement: direct and global light
    # A projector next to the camera, covering everything it sees.
    "projectorPosition": [0.3, 1.0, 6.8], "projectorDirection": [-0.3, 0.0, -6.8],
    "projectorFov": [30.0, 30.0], "projectorIntensity": [10.0, 10.0, 10.0],
    "checkerCells": [64, 64],
    "useSingleChannel": True, "singleChannel": "luminance",
}


def create_graph(properties):
    graph = testbed.create_render_graph("StructuredLight")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Tracer", "StructuredLightPathTracerInline", {**STRUCTURED_LIGHT, **properties})
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    return graph


def render(graph, seconds=None, frames=None):
    testbed.render_graph = graph
    testbed.frame()  # compiles the shaders
    start = time.perf_counter()
    while time.perf_counter() - start < 0.2:  # warm up the GPU
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


# 3. The white image and the true direct and global light
white, _ = render(create_graph({"pattern": "constant", "samplingMethod": "bsdf",
                                "samplesPerPixel": 16}), frames=CONVERGED_FRAMES)
true_direct, _ = render(create_graph({"pattern": "constant", "maxBounces": 1}), frames=1)
true_global = white - true_direct


# 4. Capture the shifted checkerboards
def capture(method):
    images, spp = [], 0
    for shift in range(SHIFTS):
        image, count = render(create_graph({"pattern": "checkerboard", "checkerShift": shift,
                                            "samplingMethod": method}), seconds=SECONDS)
        images.append(image)
        spp += count
    return np.stack(images), spp // SHIFTS


# 5. Separate
def separate(images):
    """With a pattern P in {-1, 1} the measurement is S = D P + G_s, where G_s, the global
    light under the zero-mean pattern, nearly cancels for fine cells. The inverted pattern
    gives -S, so the pixel is lit in one of the two: the brightest of the 50 images is
    (W + max |S|) / 2 and the darkest (W - max |S|) / 2, with W the white image. Their
    difference is the direct light and twice the darkest is the global light (Nayar et al.)."""
    direct = np.abs(images).max(axis=0)
    return direct, white - direct


def relative_mse(image, reference):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


results = {}
for name, method in [("Naive", "bsdf"), ("Antithetic", "antithetic")]:
    images, spp = capture(method)
    direct, global_ = separate(images)
    error = relative_mse(global_, true_global)
    print(f"{name}: {spp} spp per image, relMSE direct {relative_mse(direct, true_direct):.4f}, "
          f"global {error:.4f}")
    results[name] = (direct, global_, spp, error)

# 6. Show the components and their errors
fig, axes = plt.subplots(2, 4, figsize=(16, 8.8))
for row, (component, truth) in enumerate([("Direct", true_direct), ("Global", true_global)]):
    scale = np.percentile(truth, 99)
    axes[row, 0].imshow(np.clip(truth / scale, 0, 1) ** (1 / 2.2), cmap="gray")
    axes[row, 0].set_title(f"{component}, true")
    for column, name in enumerate(["Naive", "Antithetic"]):
        image, spp = results[name][row], results[name][2]
        axes[row, 1 + column].imshow(np.clip(image / scale, 0, 1) ** (1 / 2.2), cmap="gray")
        axes[row, 1 + column].set_title(f"{component}, {name.lower()} ({spp} spp)")
# The errors of the two components are the same: they add up to the white image.
for row, name in enumerate(["Naive", "Antithetic"]):
    error = (results[name][1] - true_global) ** 2 / np.mean(true_global ** 2)
    axes[row, 3].imshow(error, cmap="magma", vmin=0, vmax=4)
    axes[row, 3].set_title(f"Squared error, {name.lower()}\nrelMSE {results[name][3]:.3g}")
for ax in axes.ravel():
    ax.set_xticks([])
    ax.set_yticks([])
fig.tight_layout()
fig.savefig("direct_global_separation.png", dpi=100)
