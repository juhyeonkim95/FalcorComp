"""Doppler spectrum (optical heterodyne detection) of the Cornell box with DopplerHistogramPathTracerInline."""
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

# 2. Build the render graph
F_MIN, F_MAX, BINS = -100.0, 100.0, 256  # Doppler shifts, MHz

graph = testbed.create_render_graph("DopplerSpectrum")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera, as in a lidar.
graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
})
graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "maxBounces": 3, "computeDirect": True,
    "wavelength": 1550.0,  # nm
    "frequencyMin": F_MIN, "frequencyMax": F_MAX, "frequencyBin": BINS,
    # The camera looks along -z: the tall box comes towards it, the short box moves away. Nothing moves in the
    # scene; the velocities only decide the Doppler shift of each path.
    "velocities": {"TallBox": {"linear": [0.0, 0.0, 20.0]}, "ShortBox": {"linear": [0.0, 0.0, -20.0]}},
    "accumulate": True,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.mark_output("Tracer.spectrum")
testbed.render_graph = graph

# 3. Render
FRAMES = 64  # 64 frames x 64 spp
for _ in range(FRAMES):
    testbed.frame()

# 4. Read the spectrum
# With accumulate, the spectrum is the sum of the frames, per MHz: divide by the frame count for the mean.
spectrum = graph.get_output("Tracer.spectrum").to_numpy()[..., :3].mean(-1) / FRAMES  # (bins, height, width)
np.save("doppler_spectrum.npy", spectrum)
frequencies = F_MIN + (np.arange(BINS) + 0.5) * (F_MAX - F_MIN) / BINS  # bin centers, MHz

# 5. Show the image, the mean Doppler shift and three spectra
image = spectrum.sum(0) * (F_MAX - F_MIN) / BINS  # the steady image: the spectrum summed over frequency
mean_shift = (spectrum * frequencies[:, None, None]).sum(0) / np.maximum(spectrum.sum(0), 1e-12)
pixels = {"tall box": (140, 90), "short box": (185, 175), "back wall": (60, 200)}

figure, axes = plt.subplots(1, 3, figsize=(15, 4.4))
axes[0].imshow(np.clip(image / np.percentile(image, 99), 0, 1) ** (1 / 2.2), cmap="gray")
axes[0].set_title("steady image")
shown = axes[1].imshow(mean_shift, cmap="bwr", vmin=-30, vmax=30)
axes[1].set_title("mean Doppler shift (MHz)")
figure.colorbar(shown, ax=axes[1])
for (name, (y, x)), color in zip(pixels.items(), ["C0", "C1", "C2"]):
    for axis in axes[:2]:
        axis.plot(x, y, "o", mfc="none", mec=color, mew=2)
    axes[2].semilogy(frequencies, spectrum[:, y, x] + 1e-6, color=color, label=name)
axes[2].set_xlabel("Doppler shift (MHz)")
axes[2].set_title("spectra (per MHz)")
axes[2].legend()
for axis in axes[:2]:
    axis.set_xticks([])
    axis.set_yticks([])
figure.tight_layout()
figure.savefig("doppler_spectrum.png", dpi=90)
