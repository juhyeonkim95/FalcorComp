"""Depth of the bunny scene from structured light: 10-bit Gray and XOR codes (Gupta et al.
2011), decoded to projector columns and triangulated, with naive and antithetic sampling."""
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

BITS = 10              # 2^10 = 1024 projector columns
SECONDS = 0.03         # rendering time of each bit image (equal time)
CONVERGED_FRAMES = 64  # 64 frames x 16 spp for the converged Gray-code images

# 2. Build the render graph
# The projector is 0.8 to the right of the camera and looks at the middle of the
# box; its field of view covers everything the camera sees.
PROJECTOR = {"projectorPosition": [0.8, 1.0, 6.8], "projectorDirection": [-0.8, 0.0, -6.8],
             "projectorFov": [34.0, 34.0], "projectorIntensity": [10.0, 10.0, 10.0]}
STRUCTURED_LIGHT = {
    "samplesPerPixel": 1, "maxBounces": 4,
    "computeDirect": True,  # the full measurement: direct and indirect light
    "patternAxis": "u",     # vertical stripes: codes for the projector column
    "patternBits": BITS,
    "useSingleChannel": True, "singleChannel": "luminance",
    **PROJECTOR,
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


# 3. The true depth, the camera rays, and the pixels the projector lights
graph = testbed.create_render_graph("Depth")
graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.mark_output("GBuffer.posW")
graph.mark_output("GBuffer.viewW")
testbed.render_graph = graph
testbed.frame()
positions = graph.get_output("GBuffer.posW").to_numpy()[..., :3]
true_depth = np.linalg.norm(positions - camera_position, axis=-1)
ray_directions = -graph.get_output("GBuffer.viewW").to_numpy()[..., :3]
# Direct light under a white pattern: zero where the projector does not reach.
direct_white, _ = render(create_graph({"pattern": "constant", "maxBounces": 1}), frames=1)
lit = direct_white > 1e-3 * direct_white.max()


# 4. Capture one image per bit
def capture(code, base_bit, method, seconds=None, frames=None):
    """Signed measurements of bits 0 (finest stripes) to BITS - 1 of a code."""
    images, spp = [], 0
    for bit in range(BITS):
        properties = {"pattern": code, "patternBit": bit, "patternBaseBit": base_bit,
                      "samplingMethod": method}
        if frames is not None:
            properties["samplesPerPixel"] = 16
        image, count = render(create_graph(properties), seconds, frames)
        images.append(image)
        spp += count * properties.get("samplesPerPixel", 1)
    return np.stack(images), spp // BITS


# 5. Decode the projector column of every pixel
def decode(images, base_bit=None):
    """A bit is 1 where its signed measurement is positive. The XOR codes are undone with
    their base bit; the Gray code is then turned into the column index."""
    bits = images > 0
    if base_bit is not None:
        bits[base_bit + 1:] ^= bits[base_bit]
    column = np.zeros(images.shape[1:], dtype=np.int64)
    binary = np.zeros(images.shape[1:], dtype=bool)
    for bit in reversed(range(BITS)):
        binary ^= bits[bit]
        column |= binary.astype(np.int64) << bit
    return column


def confidence(images):
    """The magnitude of the least certain bit."""
    return np.abs(images).min(axis=0)


# 6. Triangulate: intersect each camera ray with the plane of light of its column
def triangulate(column):
    forward = np.array(PROJECTOR["projectorDirection"]) / np.linalg.norm(PROJECTOR["projectorDirection"])
    right = np.cross(forward, [0.0, 1.0, 0.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, forward)
    x = (2.0 * (column + 0.5) / 2 ** BITS - 1.0) * np.tan(np.radians(PROJECTOR["projectorFov"][0]) / 2)
    normal = np.cross(forward + x[..., None] * right, up)  # normal of the column's plane
    offset = np.array(PROJECTOR["projectorPosition"]) - camera_position
    return np.sum(offset * normal, -1) / np.sum(ray_directions * normal, -1)


# 7. Reconstruct
results = []
images, spp = capture("gray", 0, "bsdf", frames=CONVERGED_FRAMES)
results.append((f"Gray code, converged\n({spp} spp per bit)", triangulate(decode(images))))
for name, method in [("naive", "bsdf"), ("antithetic", "antithetic")]:
    xor02, spp = capture("xor", 0, method, seconds=SECONDS)
    xor04, _ = capture("xor", 1, method, seconds=SECONDS)
    column02, column04 = decode(xor02, 0), decode(xor04, 1)
    results.append((f"XOR-02, {name}\n({spp} spp per bit)", triangulate(column02)))
    # Ensemble: in every pixel, the code whose least certain bit is the most certain.
    column = np.where(confidence(xor02) >= confidence(xor04), column02, column04)
    results.append((f"XOR-02 + XOR-04, {name}\n({spp} spp per bit)", triangulate(column)))

# 8. Compare with the true depth
fig, axes = plt.subplots(2, 3, figsize=(10.5, 8.8))
low, high = np.percentile(true_depth[lit], [1, 99])
# Top: Gray code and XOR-02; bottom: the true depth and the XOR ensembles.
panels = [results[0], results[1], results[3], ("True depth", true_depth), results[2], results[4]]
for ax, (label, depth) in zip(axes.ravel(), panels):
    depth = np.where(lit, depth, np.nan)  # pixels in the projector's shadow have no code
    wrong = np.mean(np.abs(depth - true_depth)[lit] > 0.05)
    if label != "True depth":
        label += f"\n{100 * wrong:.1f}% wrong by > 0.05"
        print(label.replace("\n", " "))
    ax.imshow(depth, cmap="viridis", vmin=low, vmax=high)
    ax.set_title(label, fontsize=10)
    ax.set_xticks([])
    ax.set_yticks([])
fig.tight_layout()
fig.savefig("structured_light_depth.png", dpi=100)
