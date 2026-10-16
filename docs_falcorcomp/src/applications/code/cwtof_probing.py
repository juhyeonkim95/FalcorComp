"""Depth without multipath error from CW-ToF with transport probing (O'Toole et al. 2014): a projector at the camera,
and measurements that keep only the light whose projector ray is its camera ray, or only the rest."""
# 1. Build the scene
import time
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

# A white concave corner, the floor and two walls, with a box in it: light bounces between the faces (meters).
SCENE = """
camera = Camera()
camera.position = float3(1.8, 1.4, 1.8)
camera.target = float3(-0.4, 0.5, -0.4)
camera.up = float3(0.0, 1.0, 0.0)
camera.focalLength = 30.0
sceneBuilder.addCamera(camera)
white = StandardMaterial('White')
white.baseColor = float4(0.8, 0.8, 0.8, 1.0)
white.roughness = 1.0
white.metallic = 0.0
for name, size, center in [('Floor', float3(2.0, 0.02, 2.0), float3(0.0, -0.01, 0.0)),
                           ('Back', float3(2.0, 2.0, 0.02), float3(0.0, 1.0, -1.01)),
                           ('Left', float3(0.02, 2.0, 2.0), float3(-1.01, 1.0, 0.0)),
                           ('Box', float3(0.5, 0.5, 0.5), float3(-0.45, 0.25, -0.45))]:
    transform = Transform()
    transform.translation = center
    sceneBuilder.addMeshInstance(sceneBuilder.addNode(name, transform),
                                 sceneBuilder.addTriangleMesh(TriangleMesh.createCube(size), white))
"""
Path("cwtof_probing.pyscene").write_text(SCENE)

SIZE = 256
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cwtof_probing.pyscene")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()
position = testbed.scene.camera.position
camera_position = np.array([position.x, position.y, position.z])

# 2. Build the render graph
WAVELENGTH = 15.0  # path length of one modulation period, m: 20 MHz. The round trips here are shorter: no wrapping.
FRAMES = 64        # 64 frames x 16 spp per measurement


def measure(probing):
    """The complex CW-ToF measurement sum f exp(2 pi i l / wavelength) over the paths, l their lengths, weighted by
    the transport probing `probing`. Every call builds a new graph, so every measurement traces the same paths."""
    graph = testbed.create_render_graph("Probing")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    # A projector at the camera, with the camera's field of view: it lights everything the camera sees.
    graph.create_pass("Light", "LaserLight", {
        "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
        "projector": {"fov": [0.0, 0.0], "pattern": "constant"},
    })
    graph.create_pass("Tracer", "CWToFPathTracerInline", {
        "samplesPerPixel": 16, "maxBounces": 6, "computeDirect": True,
        "waveform": "cos", "modulationWavelength": WAVELENGTH,
        "phaseShift": [0.0, 0.25, 0.0],  # red: sum f cos(2 pi l / wavelength), green: sum f sin(...)
        **probing,
    })
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "Single"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Light", "Tracer")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    testbed.render_graph = graph
    for _ in range(FRAMES):
        testbed.frame()
    image = graph.get_output("Accumulate.output").to_numpy()
    return image[..., 0].astype(np.float64) + 1j * image[..., 1]


# 3. Measure, with and without probing
start = time.perf_counter()
measurements = {
    "conventional": measure({"probing": "none"}),
    "epipolar": measure({"probing": "epipolar"}),          # direct and retro-reflective light
    "non_epipolar": measure({"probing": "non_epipolar"}),  # the rest, the indirect light
    "masks": measure({"probing": "masks", "probingMaskCount": 128}),  # 128 random mask and pattern pairs
}
print(f"4 measurements in {time.perf_counter() - start:.0f} s")
conventional = measurements["conventional"]
lit = np.abs(conventional) > 1e-3 * np.abs(conventional).max()
residual = np.abs(conventional - measurements["epipolar"] - measurements["non_epipolar"])[lit].max()
print(f"|conventional - epipolar - non_epipolar| / max |conventional|: {residual / np.abs(conventional).max():.1e}")
share = np.abs(measurements["non_epipolar"])[lit].sum() / np.abs(measurements["epipolar"])[lit].sum()
print(f"non-epipolar / epipolar light, summed magnitudes: {share:.3f}")

# 4. Depth from the phase
graph = testbed.create_render_graph("Depth")
graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.mark_output("GBuffer.posW")
testbed.render_graph = graph
testbed.frame()
positions = graph.get_output("GBuffer.posW").to_numpy()[..., :3]
true_depth = np.linalg.norm(positions - camera_position, axis=-1)


def depth(measurement):
    """The phase is 2 pi l / wavelength, and the path length l of the direct light is twice the depth."""
    phase = np.angle(measurement) % (2.0 * np.pi)
    return phase / (2.0 * np.pi) * WAVELENGTH / 2.0


# The masks give the indirect light as a camera would measure it; the conventional measurement minus it is the
# direct and retro-reflective light (O'Toole et al. 2014, Algorithm 3).
depths = {
    "conventional": depth(conventional),
    "epipolar": depth(measurements["epipolar"]),
    "conventional - masks": depth(conventional - measurements["masks"]),
}
for name, estimate in depths.items():
    error = (estimate - true_depth)[lit]
    print(f"{name}: median |depth error| {np.median(np.abs(error)) * 1e3:.2f} mm, "
          f"95th percentile {np.percentile(np.abs(error), 95) * 1e3:.2f} mm")
# The masks leave less indirect light the more of them take turns in the exposure.
for count in [8, 32, 128]:
    masked = measurements["masks"] if count == 128 else measure({"probing": "masks", "probingMaskCount": count})
    error = (depth(conventional - masked) - true_depth)[lit]
    print(f"conventional - masks, K = {count}: median |depth error| {np.median(np.abs(error)) * 1e3:.2f} mm")

# 5. Show the measurements and the depth errors
fig, axes = plt.subplots(2, 4, figsize=(16, 8.4), layout="constrained")
top = np.percentile(np.abs(conventional[lit]), 99)
titles = {"conventional": "conventional", "epipolar": "epipolar: direct + retro-reflective",
          "non_epipolar": "non-epipolar: indirect", "masks": "masks (K = 128)"}
for axis, (name, measurement) in zip(axes[0], measurements.items()):
    axis.imshow((np.abs(measurement) / top).clip(0, 1) ** (1 / 2.2), cmap="gray", vmin=0, vmax=1)
    axis.set_title(f"|I|, {titles[name]}")
shown = axes[1, 0].imshow(np.where(lit, true_depth, np.nan), cmap="viridis")
axes[1, 0].set_title("true depth (m)")
fig.colorbar(shown, ax=axes[1, 0], shrink=0.8)
for axis, (name, estimate) in zip(axes[1, 1:], depths.items()):
    error = np.where(lit, estimate - true_depth, np.nan) * 1e3
    shown = axis.imshow(error, cmap="RdBu_r", vmin=-150, vmax=150)
    axis.set_title(f"depth error (mm), {name}\nmedian |error| {np.nanmedian(np.abs(error)):.1f} mm")
fig.colorbar(shown, ax=axes[1, 1:], shrink=0.8)
for axis in axes.ravel():
    axis.set_xticks([])
    axis.set_yticks([])
fig.savefig("cwtof_probing.png", dpi=70)
np.savez("cwtof_probing.npz", true_depth=true_depth, lit=lit, **measurements)
