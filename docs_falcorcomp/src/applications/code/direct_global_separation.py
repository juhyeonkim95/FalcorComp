"""Separation of the direct and global light with high-frequency checkerboards (Nayar et
al. 2006), with naive and antithetic sampling of the indirect light."""
# 1. Load the scene
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

SIZE = 1024
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box-separation/scene-v4.pbrt")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SHIFTS = 25           # checkerboards shifted by fifths of a cell, 5 x 5
# Indirect samples per pixel of each image. An antithetic sample also traces its
# antithetic path, so it gets half as many.
SPP = {"naive": 64, "antithetic": 32}
CONVERGED_SPP = 2048  # samples per pixel of the white images

# 2. The projector and the render graph
# The projector is collocated with the camera: at its position, looking the same way,
# with a field of view a little wider than the camera's (tan of the half angle 0.2). It
# then lights everything the camera sees, without shadows.
PROJECTOR = {
    "projectorPosition": [0.0, 1.0, 6.8], "projectorDirection": [0.0, 0.0, -1.0],
    "projectorFov": [2 * np.degrees(np.arctan(0.2))] * 2,
    "projectorIntensity": [10.0, 10.0, 10.0],
}
# A checkerboard of 1024 x 1024 cells: each cell is about one pixel.
TRACER = {"maxBounces": 6, "checkerCells": [1024, 1024], **PROJECTOR}

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
    """One RGB image with the tracer set to `properties`, averaged over `spp` frames."""
    graph.update_pass("Tracer", {**TRACER, "samplesPerPixel": 1, **properties})
    testbed.frame()  # compiles the shaders
    graph.get_pass("Accumulate").reset()
    for _ in range(spp):
        testbed.frame()
    return graph.get_output("Accumulate.output").to_numpy()[..., :3].copy()


# 3. The white image, and the true direct and global light
white = render({"pattern": "constant"}, CONVERGED_SPP)
true_direct = render({"pattern": "constant", "maxBounces": 1}, CONVERGED_SPP)
true_global = white - true_direct

# 4. Capture the checkerboards and their inverses
# The pass renders the signed pattern P = +-1. The image under the binary checkerboard
# (1 where P = 1, 0 elsewhere) is (white + signed) / 2. The direct light of each pattern
# is rendered first, once (it is easy to converge); only the indirect light, the hard
# part, is rendered with each method.
patterns = [{"pattern": "checkerboard", "checkerShift": shift, "invertPattern": inverse}
            for shift in range(SHIFTS) for inverse in [False, True]]
direct_images = [render({**pattern, "maxBounces": 1}, CONVERGED_SPP // 16) for pattern in patterns]


def capture(method):
    images = []
    for pattern, direct in zip(patterns, direct_images):
        indirect = render({**pattern, "computeDirect": False, "samplingMethod": method}, SPP[method])
        images.append(0.5 * (white + direct + indirect))
    return np.stack(images)


# 5. Separate (Nayar et al.): a point is lit in some images and dark in others. Lit, it
# gets its direct light and half its global light; dark, only half its global light.
def separate(images):
    brightest, darkest = images.max(axis=0), images.min(axis=0)
    return brightest - darkest, np.maximum(2.0 * darkest, 0.0)


def luminance(image):
    return image @ np.array([0.2126, 0.7152, 0.0722])


def tone_map(image):
    """Reinhard on the luminance, after scaling by 10, then gamma."""
    image = 10.0 * np.maximum(image, 0.0)
    return np.clip(image / (1.0 + luminance(image)[..., None] / 1.5), 0, 1) ** (1 / 2.2)


results = {}
for method in ["naive", "antithetic"]:
    direct, global_ = separate(capture(method))
    errors = [np.mean(luminance(direct - true_direct) ** 2),
              np.mean(luminance(global_ - true_global) ** 2)]
    print(f"{method} ({SPP[method]} spp): MSE direct {errors[0]:.2e}, global {errors[1]:.2e}")
    results[method] = (direct, global_, errors, SPP[method])

# 6. Show the components and their squared errors
# The 1024 x 1024 images are shown smaller, filtered (interpolation="antialiased").
fig, axes = plt.subplots(2, 5, figsize=(15, 6.8))
for row, (component, truth) in enumerate([("Direct", true_direct), ("Global", true_global)]):
    axes[row, 0].imshow(tone_map(truth), interpolation="antialiased")
    axes[row, 0].set_title(f"{component}, true", fontsize=10)
    for column, (name, (direct, global_, errors, spp)) in enumerate(results.items()):
        image = (direct, global_)[row]
        axes[row, 1 + column].imshow(tone_map(image), interpolation="antialiased")
        axes[row, 1 + column].set_title(f"{component}, {name} ({spp} spp)", fontsize=10)
        axes[row, 3 + column].imshow(luminance(image - truth) ** 2, vmin=0, vmax=1e-4, cmap="inferno",
                                        interpolation="antialiased", interpolation_stage="rgba")
        axes[row, 3 + column].set_title(f"Squared error, {name}\nMSE {errors[row]:.2e}", fontsize=10)
for ax in axes.ravel():
    ax.set_xticks([])
    ax.set_yticks([])
fig.tight_layout()
fig.savefig("direct_global_separation.png", dpi=100)
