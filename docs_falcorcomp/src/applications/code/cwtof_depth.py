"""Depth of the bunny scene from CW-ToF measurements: four phase-shifted images per
modulation wavelength, phase to depth, and np.unwrap against a coarse depth."""
# 1. Load the scene
import time

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box-bunny-diffuse/scene-v4.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()
position = testbed.scene.camera.position
camera_position = np.array([position.x, position.y, position.z])

PHASES = [0.0, 0.25, 0.5, 0.75]  # in periods
SECONDS = 0.02                   # rendering time of each phase image (equal time)
CONVERGED_FRAMES = 256           # 256 frames x 16 spp for the converged measurements

# 2. Build the render graph
CWTOF = {
    "samplesPerPixel": 1, "maxBounces": 4,
    "computeDirect": True,  # the full measurement: direct and indirect light
    "waveform": "cos",
    "useSingleChannel": True, "singleChannel": "luminance",
}
NAIVE = {"useAntitheticSampling": False}
ANTITHETIC = {"useAntitheticSampling": True, "shiftMappingMethod": "barycentric"}


def create_graph(properties):
    graph = testbed.create_render_graph("CWToF")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    # A point light at the camera, as in a CW-ToF camera.
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


def render(graph, seconds=None, frames=None):
    testbed.render_graph = graph
    testbed.frame()  # compiles the shaders
    start = time.perf_counter()
    while time.perf_counter() - start < 0.3:  # warm up the GPU
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


# 3. The true depth, from the G-buffer's world positions
graph = testbed.create_render_graph("Depth")
graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.mark_output("GBuffer.posW")
testbed.render_graph = graph
testbed.frame()
positions = graph.get_output("GBuffer.posW").to_numpy()[..., :3]
true_depth = np.linalg.norm(positions - camera_position, axis=-1)  # distance from the camera


# 4. Capture four phase-shifted images
def capture(wavelength, method, seconds=None, frames=None):
    images, spp = [], 0
    for phase in PHASES:
        properties = {**method, "modulationWavelength": wavelength, "phase": phase}
        if frames is not None:
            properties["samplesPerPixel"] = 16
        image, count = render(create_graph(properties), seconds, frames)
        images.append(image)
        spp += count * properties.get("samplesPerPixel", 1)
    return images, spp // len(PHASES)


# 5. Phase to depth
def depth_from_phases(images, wavelength, coarse_depth):
    """The phase gives the path length l (twice the depth: the light is at the camera)
    up to multiples of the wavelength; np.unwrap picks the multiple closest to a coarse
    depth, as from a lower modulation frequency or another sensor."""
    i0, i1, i2, i3 = images
    phase = np.arctan2(i1 - i3, i0 - i2)  # 2 pi l / wavelength, wrapped to (-pi, pi]
    coarse_phase = 2.0 * np.pi * (2.0 * coarse_depth) / wavelength
    phase = np.unwrap(np.stack([coarse_phase, phase]), axis=0)[1]
    return phase / (2.0 * np.pi) * wavelength / 2.0


# Here the coarse depth is the true depth: it only picks the multiple, and the
# measured phase still decides the depth within a quarter wavelength of it.
coarse = true_depth
results = []
long_images, spp = capture(1.0, NAIVE, frames=CONVERGED_FRAMES)
results.append((f"$\\lambda$ = 1, converged ({spp} spp)", depth_from_phases(long_images, 1.0, coarse)))
for name, method in [("naive", NAIVE), ("antithetic", ANTITHETIC)]:
    images, spp = capture(0.02, method, seconds=SECONDS)
    results.append((f"$\\lambda$ = 0.02, {name} ({spp} spp)", depth_from_phases(images, 0.02, coarse)))

# 6. Compare with the true depth
fig, axes = plt.subplots(1, 4, figsize=(16, 4.4))
im = axes[0].imshow(results[-1][1], cmap="viridis")
axes[0].set_title("Depth ($\\lambda$ = 0.02, antithetic)")
fig.colorbar(im, ax=axes[0], fraction=0.046)
for ax, (label, depth) in zip(axes[1:], results):
    error = depth - true_depth
    print(f"{label}: median |error| {np.median(np.abs(error)):.2e}")
    limit = 0.02 if "= 1," in label else 0.001
    im = ax.imshow(error, cmap="bwr", vmin=-limit, vmax=limit)
    ax.set_title(f"Error, {label}\nmedian |error| {np.median(np.abs(error)):.1e}", fontsize=10)
    fig.colorbar(im, ax=ax, fraction=0.046)
for ax in axes:
    ax.set_xticks([])
    ax.set_yticks([])
fig.tight_layout()
fig.savefig("cwtof_depth.png", dpi=100)
