"""FMCW lidar: up- and down-chirp spectra of the Cornell box with DopplerHistogramPathTracerInline, and the distance
and velocity they give, from the mean spectrum and from a single measurement with speckle."""
# 1. Load the scene
import falcorcomp as falcor
import numpy as np
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

testbed = falcor.Testbed(create_window=False)
# Keep every material separate, so that each object keeps its name (identical materials are merged by default).
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.resize_frame_buffer(256, 256)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()
position = testbed.scene.camera.position
camera_position = np.array([position.x, position.y, position.z])

# 2. Build the render graph
WAVELENGTH = 1550.0                 # nm
BANDWIDTH, DURATION = 1.0, 1.0      # the chirp: 1 GHz in 1 us, up and then down
F_MIN, F_MAX, BINS = 0.0, 100.0, 512  # beat frequencies, MHz
VELOCITIES = {"TallBox": {"linear": [0.0, 0.0, 20.0]}, "ShortBox": {"linear": [0.0, 0.0, -20.0]}}  # m/s
# The range term of the beat frequency per meter of path length, B / (T c), in MHz per meter.
RANGE_FREQUENCY_PER_LENGTH = BANDWIDTH * 1000.0 / (DURATION * 299.792458)

graph = testbed.create_render_graph("FMCW")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera, as in a lidar.
graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
})
graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "maxBounces": 3, "computeDirect": True,
    "wavelength": WAVELENGTH,
    "chirpBandwidth": BANDWIDTH, "chirpDuration": DURATION,  # GHz, us: a triangular chirp
    "frequencyMin": F_MIN, "frequencyMax": F_MAX, "frequencyBin": BINS,
    "velocities": VELOCITIES,
    "useSingleChannel": True, "singleChannel": "luminance",  # one value per bin: a quarter of the memory
    "accumulate": True,
})
# The true distance (from the world positions) and velocity, for comparison.
graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Truth", "VelocityGroundTruthInline", {"mode": "doppler", "velocities": VELOCITIES})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.add_edge("Light", "Truth")
graph.mark_output("Tracer.spectrum")      # up-chirp
graph.mark_output("Tracer.spectrumDown")  # down-chirp
graph.mark_output("GBuffer.posW")
graph.mark_output("Truth.velocity")
testbed.render_graph = graph

# 3. Render
FRAMES = 64  # 64 frames x 64 spp
for _ in range(FRAMES):
    testbed.frame()

# 4. Read the spectra
# With accumulate, a spectrum is the sum of the frames, per MHz: divide by the frame count for the mean.
up = graph.get_output("Tracer.spectrum").to_numpy() / FRAMES         # (bins, height, width)
down = graph.get_output("Tracer.spectrumDown").to_numpy() / FRAMES
frequencies = F_MIN + (np.arange(BINS) + 0.5) * (F_MAX - F_MIN) / BINS     # bin centers, MHz
# The true distance to the primary hit and velocity towards the camera; NaN where the camera ray misses (a few
# pixels along a crack in the bottom-right corner).
position = graph.get_output("GBuffer.posW").to_numpy()
hit = position[..., 3] > 0
true_distance = np.where(hit, np.linalg.norm(position[..., :3] - camera_position, axis=-1), np.nan)
true_velocity = np.where(hit, graph.get_output("Truth.velocity").to_numpy().reshape(hit.shape), np.nan)


# 5. Distance and velocity from the two peaks
def reconstruct(up, down):
    """The beat frequency is f_R - f_D on the up-chirp and f_R + f_D on the down-chirp."""
    f_up = frequencies[np.argmax(up, axis=0)]
    f_down = frequencies[np.argmax(down, axis=0)]
    f_range, f_doppler = (f_up + f_down) / 2, (f_down - f_up) / 2
    # The light is at the camera: the path length is twice the distance.
    distance = f_range / RANGE_FREQUENCY_PER_LENGTH / 2
    # f_D = u / wavelength, and the path velocity u is twice the velocity towards the camera.
    velocity = f_doppler * WAVELENGTH / 1000.0 / 2
    return distance, velocity


distance, velocity = reconstruct(up, down)
distance[~hit] = velocity[~hit] = np.nan

# 6. A single measurement
# Speckle makes the power of each bin exponentially distributed around the mean spectrum (Kim et al. 2025,
# Algorithm 1).
rng = np.random.default_rng(0)
up_single = rng.exponential(up)
down_single = rng.exponential(down)
distance_single, velocity_single = reconstruct(up_single, down_single)
distance_single[~hit] = velocity_single[~hit] = np.nan

# 7. Show the image and the spectra of three pixels, in dB
image = up.sum(0) * (F_MAX - F_MIN) / BINS  # the steady image: the spectrum summed over frequency
pixels = {"A: tall box": (140, 90), "B: short box": (185, 175), "C: back wall": (60, 200)}
figure, axes = plt.subplots(1, 4, figsize=(17, 4.4), gridspec_kw={"width_ratios": [1, 1.4, 1.4, 1.4]},
                           constrained_layout=True)
axes[0].imshow(np.clip(image / np.percentile(image, 99), 0, 1) ** (1 / 2.2), cmap="gray")
axes[0].set_title("steady image")
axes[0].set_xticks([])
axes[0].set_yticks([])
for axis, (name, (y, x)) in zip(axes[1:], pixels.items()):
    axes[0].plot(x, y, "o", mfc="none", mec="C1", mew=2)
    axes[0].annotate(name[0], (x, y), xytext=(7, -7), textcoords="offset points", color="C1", weight="bold")
    peak = max(up[:, y, x].max(), down[:, y, x].max())
    for mean, single, chirp, color in [(up, up_single, "up", "C0"), (down, down_single, "down", "C3")]:
        axis.plot(frequencies, 10 * np.log10(single[:, y, x] / peak + 1e-9), color=color, lw=0.8, alpha=0.35,
                  label=f"{chirp}, one measurement")
        axis.plot(frequencies, 10 * np.log10(mean[:, y, x] / peak + 1e-9), color=color, lw=1.5,
                  label=f"{chirp}, mean")
    # The range term of the true distance: the up- and down-chirp peaks sit at f_R -+ f_D around it.
    axis.axvline(2 * true_distance[y, x] * RANGE_FREQUENCY_PER_LENGTH, color="gray", ls="--", lw=1,
                 label="$f_R$ (true distance)")
    axis.set_title(f"{name}: {true_distance[y, x]:.2f} m, {true_velocity[y, x]:+.1f} m/s")
    axis.set_xlabel("beat frequency (MHz)")
    axis.set_xlim(F_MIN, F_MAX)
    axis.set_ylim(-45, 12)
    # The distance at which a static reflector would give this beat frequency.
    axis.secondary_xaxis("top", functions=(lambda f: f / (2 * RANGE_FREQUENCY_PER_LENGTH),
                                           lambda d: d * 2 * RANGE_FREQUENCY_PER_LENGTH)).set_xlabel(
        "distance if static (m)")
axes[1].set_ylabel("power (dB, relative to the peak)")
axes[3].legend(fontsize=8, loc="upper right")
figure.savefig("fmcw_spectra.png", dpi=90)

# 8. Show the distance and velocity
figure, axes = plt.subplots(2, 3, figsize=(12, 7.6), constrained_layout=True)
for row, (name, truth, mean, single, colormap, limits) in enumerate([
        ("distance (m)", true_distance, distance, distance_single, "viridis", (6.0, 8.6)),
        ("velocity (m/s)", true_velocity, velocity, velocity_single, "bwr", (-20, 20))]):
    for axis, (title, values) in zip(axes[row], [("true", truth), ("from the mean spectra", mean),
                                                  ("from one measurement", single)]):
        shown = axis.imshow(values, cmap=colormap, vmin=limits[0], vmax=limits[1], interpolation="nearest")
        axis.set_title(f"{name}, {title}")
        axis.set_xticks([])
        axis.set_yticks([])
    figure.colorbar(shown, ax=axes[row].tolist(), fraction=0.03)
figure.savefig("fmcw_reconstruction.png", dpi=90)
