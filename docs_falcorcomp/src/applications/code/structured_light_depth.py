"""3D reconstruction of the bunny scene from structured light: XOR-02 and XOR-04 codes
(Gupta et al. 2011) along both projector axes, decoded to projector pixels and
triangulated, with naive and antithetic sampling of the indirect light."""
# 1. Load the scene
import time

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

SIZE = 1024
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box-bunny-diffuse/scene-v4.pbrt")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

BITS = 10                 # 2^10 = 1024 projector columns and rows
NAIVE_SPP = 512           # indirect samples per pixel of each naive image
CONVERGED_SPP = 2048      # samples per pixel of the white, direct and reference images
CAMERA_POSITION = np.array([0.0, 1.0, 6.8])
CAMERA_FOV = 19.5         # degrees, vertical, from the scene file

# 2. The projector and the render graph
# A projector 0.1 to the right of the camera, looking the same way, with a field of
# view a little wider than the camera's (tan of the half angle 0.2).
PROJECTOR_POSITION = np.array([0.1, 1.0, 6.8])
TAN_HALF_FOV = 0.2
PROJECTOR = {
    "projectorPosition": PROJECTOR_POSITION.tolist(), "projectorDirection": [0.0, 0.0, -1.0],
    "projectorFov": [2 * np.degrees(np.arctan(TAN_HALF_FOV))] * 2,
    "projectorIntensity": [10.0, 10.0, 10.0],
}
TRACER = {"maxBounces": 4, "patternBits": BITS,
          "useSingleChannel": True, "singleChannel": "luminance", **PROJECTOR}

graph = testbed.create_render_graph("StructuredLight")
# Jittered primary rays (32 Halton positions per pixel) average each pixel's footprint.
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Halton", "sampleCount": 32})
graph.create_pass("Tracer", "StructuredLightPathTracerInline", TRACER)
graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Tracer.color", "Accumulate.input")
graph.mark_output("Accumulate.output")
testbed.render_graph = graph


def render(properties, spp):
    """One image with the tracer set to `properties`, averaged over `spp` frames of 1 spp."""
    graph.update_pass("Tracer", {**TRACER, "samplesPerPixel": 1, **properties})
    testbed.frame()  # compiles the shaders
    graph.get_pass("Accumulate").reset()
    for _ in range(spp):
        testbed.frame()
    return graph.get_output("Accumulate.output").to_numpy()[..., 0].copy()


# 3. Equal time: the cost of a frame of each method
def frame_time(method):
    graph.update_pass("Tracer", {**TRACER, "samplesPerPixel": 1, "computeDirect": False,
                                 "pattern": "xor", "patternBit": 5, "samplingMethod": method})
    for _ in range(100):  # compile and warm up the GPU
        testbed.frame()
    testbed.device.wait()
    start = time.perf_counter()
    for _ in range(500):
        testbed.frame()
    testbed.device.wait()
    return (time.perf_counter() - start) / 500


cost = {method: frame_time(method) for method in ["bsdf", "antithetic"]}
SPP = {"bsdf": NAIVE_SPP, "antithetic": round(NAIVE_SPP * cost["bsdf"] / cost["antithetic"])}
print(f"frame time: naive {1000 * cost['bsdf']:.2f} ms, antithetic {1000 * cost['antithetic']:.2f} ms; "
      f"antithetic gets {SPP['antithetic']} spp")

# 4. Capture the code images
# The direct light of each pattern is rendered once, converged; only the indirect light,
# the hard part, is rendered with each method.
white = render({"pattern": "constant"}, CONVERGED_SPP)
normalization = white + 0.01 * white.mean()
direct_images = {}


def capture(base_bit, axis, indirect_method):
    """Images of bits 0 (finest) to BITS - 1 of an XOR code along `axis`, divided by the
    white image. indirect_method: "bsdf" (naive), "antithetic", or None (converged)."""
    images = []
    for bit in range(BITS):
        pattern = {"pattern": "xor", "patternBaseBit": base_bit, "patternBit": bit, "patternAxis": axis}
        key = (base_bit, axis, bit)
        if key not in direct_images:
            direct_images[key] = render({**pattern, "maxBounces": 1}, CONVERGED_SPP // 16)
        if indirect_method is None:
            indirect = render({**pattern, "computeDirect": False}, CONVERGED_SPP)
        else:
            indirect = render({**pattern, "computeDirect": False, "samplingMethod": indirect_method},
                              SPP[indirect_method])
        images.append((direct_images[key] + indirect) / normalization)
    return np.stack(images)


# 5. Decode the projector pixel of every camera pixel
def decode_xor(images, base_bit):
    """A bit is 1 where its signed image is positive. Bits above the base bit are XORed
    with it; undoing that gives the Gray code, which is then turned into the index."""
    observed = images > 0
    gray = np.zeros(images.shape[1:], dtype=np.int64)
    for bit in range(BITS):
        value = observed[bit] if bit <= base_bit else observed[bit] ^ observed[base_bit]
        gray |= value.astype(np.int64) << bit
    index, shift = gray.copy(), 1
    while (gray >> shift).any():
        index ^= gray >> shift
        shift += 1
    return index


# 6. Triangulate the camera ray with the projector ray
def directions(x, y, tan_half_fov, width):
    """Unit directions through pixel (x, y) of a pinhole looking down -z, y up."""
    local = np.stack([(2 * (x + 0.5) / width - 1) * tan_half_fov,
                      (2 * (y + 0.5) / width - 1) * tan_half_fov,
                      -np.ones(np.shape(x))], axis=-1)
    return local / np.linalg.norm(local, axis=-1, keepdims=True)


rows, columns = np.meshgrid(np.arange(SIZE), np.arange(SIZE), indexing="ij")
camera_rays = directions(columns, SIZE - 1 - rows, np.tan(np.radians(CAMERA_FOV) / 2), SIZE)


def triangulate(column, row):
    """The midpoint of the closest points of the camera ray and the projector ray."""
    d1, d2 = camera_rays, directions(column, row, TAN_HALF_FOV, 2 ** BITS)
    w0 = CAMERA_POSITION - PROJECTOR_POSITION
    a, b, c = (d1 * d1).sum(-1), (d1 * d2).sum(-1), (d2 * d2).sum(-1)
    d, e = (d1 * w0).sum(-1), (d2 * w0).sum(-1)
    denominator = a * c - b * b
    t, s = (b * e - c * d) / denominator, (a * e - b * d) / denominator
    return 0.5 * (CAMERA_POSITION + t[..., None] * d1 + PROJECTOR_POSITION + s[..., None] * d2)


def reconstruct(indirect_method):
    """Points from XOR-02 and XOR-04, averaged with the confidence of each: the product
    of the magnitudes of its normalized bit images."""
    point_sum, weight_sum = 0.0, 0.0
    for base_bit in [0, 1]:  # XOR-02, XOR-04
        u_images = capture(base_bit, "u", indirect_method)  # vertical stripes: the column
        v_images = capture(base_bit, "v", indirect_method)  # horizontal stripes: the row
        points = triangulate(decode_xor(u_images, base_bit), decode_xor(v_images, base_bit))
        weight = np.prod(np.abs(u_images), axis=0) * np.prod(np.abs(v_images), axis=0) + 1e-20
        point_sum = point_sum + weight[..., None] * points
        weight_sum = weight_sum + weight[..., None]
    return point_sum / weight_sum


results = [("Converged", reconstruct(None))]
for name, method in [("Naive", "bsdf"), ("Antithetic", "antithetic")]:
    results.append((f"{name}, {SPP[method]} spp", reconstruct(method)))

# 7. Show the depth (the z coordinate) and the difference from the converged result
reference = results[0][1][..., 2]
fig, axes = plt.subplots(2, 3, figsize=(12, 8.4))
for column, (label, points) in enumerate(results):
    depth = points[..., 2]
    axes[0, column].imshow(depth, vmin=-1, vmax=1, cmap="viridis")
    axes[0, column].set_title(label)
    if column > 0:
        wrong = np.mean(np.abs(depth - reference) > 0.05)
        print(f"{label}: {100 * wrong:.2f}% of the pixels differ from the converged result by more than 0.05")
        axes[1, column].imshow(np.abs(depth - reference), vmin=0, vmax=0.2, cmap="inferno")
        axes[1, column].set_title(f"|difference|: {100 * wrong:.1f}% > 0.05")
axes[1, 0].set_visible(False)
for ax in axes.ravel():
    ax.set_xticks([])
    ax.set_yticks([])
fig.tight_layout()
fig.savefig("structured_light_depth.png", dpi=100)
