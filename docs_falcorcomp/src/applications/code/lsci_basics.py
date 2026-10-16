"""Laser speckle contrast imaging (LSCI) from the Doppler spectrum of DopplerHistogramPathTracerInline."""
# 1. Load the scene
import falcorcomp as falcor
import numpy as np
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

testbed = falcor.Testbed(create_window=False)
# Keep every material separate, so that each object keeps its name (identical materials are merged by default).
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.resize_frame_buffer(128, 128)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
F_MAX, BINS = 0.008, 1024  # Doppler shifts from -8 to 8 kHz (given in MHz), in bins of 15.6 Hz

graph = testbed.create_render_graph("SpeckleContrast")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera: wide-field illumination.
graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
})
tracer = graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "maxBounces": 4, "computeDirect": False,
    "wavelength": 785.0,  # nm
    "frequencyMin": -F_MAX, "frequencyMax": F_MAX, "frequencyBin": BINS,
    # Slow motion, as of blood flow: the tall box comes towards the camera at 1 mm/s, and the short box turns about
    # its vertical axis at 3 mrad/s (about 1 mm/s at its edges).
    "velocities": {
        "TallBox": {"linear": [0.0, 0.0, 1e-3]},
        "ShortBox": {"angular": [0.0, 3e-3, 0.0], "center": [0.329, 0.3, 0.375]},
    },
    "accumulate": True, "useSingleChannel": True,  # one wavelength: one channel
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.mark_output("Tracer.spectrum")
testbed.render_graph = graph

# 3. Render the spectrum twice
FRAMES = 128  # 128 frames x 64 spp per spectrum
BIN_MHZ = 2 * F_MAX / BINS


def render_spectrum():
    """The light in each bin, (bins, pixels): a spectrum with new samples on every call."""
    tracer.reset()
    for _ in range(FRAMES):
        testbed.frame()
    spectrum = graph.get_output("Tracer.spectrum").to_numpy()  # per MHz, summed over the frames
    return (spectrum / FRAMES * BIN_MHZ).reshape(BINS, -1)


light_a = render_spectrum()
light_b = render_spectrum()

# 4. Compute the speckle contrast
BETA = 1.0  # coherence factor: 1 when a pixel is smaller than a speckle
EXPOSURES = np.logspace(-6, -2, 41)  # 1 us to 10 ms
lags = np.concatenate([np.arange(BINS), np.arange(-BINS, 0)])  # m, in the order of a length-2B FFT
# sinc^2(m df T) for every exposure T and lag m (np.sinc(x) is sin(pi x) / (pi x)).
window = np.sinc(np.outer(EXPOSURES, lags * BIN_MHZ * 1e6)) ** 2
intensity2 = light_a.sum(0, dtype=np.float64) * light_b.sum(0, dtype=np.float64)  # I^2, from the two renders
lit = intensity2 > 0

k2 = np.empty((len(EXPOSURES), intensity2.size))
for start in range(0, intensity2.size, 2048):  # 2048 pixels at a time, to bound the memory
    pixels = slice(start, start + 2048)
    # Homodyne PSD: the autocorrelation of the spectrum, A[m] = sum_k S_k S_(k+m), with S from one render and
    # S_(k+m) from the other, so that the Monte Carlo noise of each does not add up.
    spectrum_a = np.fft.rfft(light_a[:, pixels], 2 * BINS, axis=0)
    spectrum_b = np.fft.rfft(light_b[:, pixels], 2 * BINS, axis=0)
    psd = np.fft.irfft(np.conj(spectrum_a) * spectrum_b, 2 * BINS, axis=0)
    psd = 0.5 * (psd + psd[(-lags) % (2 * BINS)])  # A[m] = A[-m]
    k2[:, pixels] = window @ psd
contrast = np.sqrt(np.clip(BETA * k2 / np.where(lit, intensity2, 1.0), 0.0, None))
contrast[:, ~lit] = np.nan
contrast = contrast.reshape(len(EXPOSURES), 128, 128)
# Static light: the bin of zero shift (0 is the lower edge of bin BINS / 2).
static = np.sqrt(np.clip(light_a[BINS // 2] * light_b[BINS // 2] / np.where(lit, intensity2, 1.0), 0.0, None))
static = np.where(lit, static, np.nan).reshape(128, 128)
np.savez("lsci_basics.npz", exposures=EXPOSURES, contrast=contrast, static_fraction=static)

# 5. Show the contrast
pixels = {"tall box": (70, 45), "short box": (100, 85), "back wall": (30, 64), "right wall": (60, 120)}
shown_exposures = [2e-4, 1e-3, 1e-2]  # s

figure, axes = plt.subplots(1, 5, figsize=(20, 3.9), gridspec_kw={"width_ratios": [1, 1, 1, 1, 1.5]})
image = axes[0].imshow(static, cmap="viridis", vmin=0, vmax=1)
axes[0].set_title("static light fraction")
figure.colorbar(image, ax=axes[0], fraction=0.046)
for axis, exposure in zip(axes[1:4], shown_exposures):
    image = axis.imshow(contrast[np.argmin(np.abs(EXPOSURES - exposure))], cmap="magma", vmin=0, vmax=1)
    axis.set_title(f"contrast K, T = {exposure * 1e3:g} ms")
    figure.colorbar(image, ax=axis, fraction=0.046)
for (name, (y, x)), color in zip(pixels.items(), ["C0", "C1", "C2", "C3"]):
    for axis in axes[:4]:
        axis.plot(x, y, "o", mfc="none", mec=color, mew=2)
    axes[4].semilogx(EXPOSURES * 1e3, contrast[:, y, x], color=color, label=name)
    axes[4].axhline(np.sqrt(BETA) * static[y, x], color=color, ls="--", lw=0.8)
axes[4].set_xlabel("exposure T (ms)")
axes[4].set_ylim(0, 1.05)
axes[4].set_title("contrast K; dashed: static light fraction")
axes[4].legend(loc="lower left")
for axis in axes[:4]:
    axis.set_xticks([])
    axis.set_yticks([])
figure.tight_layout()
figure.savefig("lsci_basics.png", dpi=75)
