"""Laser speckle contrast imaging (LSCI) of blood flow in tissue, from the Doppler spectrum of
DopplerHistogramPathTracerInline with participating media."""
# 1. Build the scene
from pathlib import Path

import falcorcomp as falcor
import numpy as np
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

# A tissue slab with a blood vessel, in meters. The slab is 8 x 3 x 8 mm with its top face at y = 0; the vessel is a
# cylinder along x, of radius 0.25 mm, its axis 0.5 mm deep. Both have the refractive index 1.4. Their optical
# properties and the blood flow are given to the render pass (step 2).
SCENE = """
import math
camera = Camera()
camera.position = float3(0.0, 0.02, 0.0)  # 20 mm above the tissue, looking down
camera.target = float3(0.0, 0.0, 0.0)
camera.up = float3(0.0, 0.0, -1.0)
camera.focalLength = 120.0  # mm, on the 24 mm frame: a 4 mm wide field of view
camera.nearPlane = 1e-3     # rays start 1 mm from the camera (the default, 0.1, would pass the tissue)
camera.farPlane = 1.0
sceneBuilder.addCamera(camera)

tissue = StandardMaterial('Tissue')
tissue.indexOfRefraction = 1.4
slab = Transform()
slab.translation = float3(0.0, -1.5e-3, 0.0)
sceneBuilder.addMeshInstance(sceneBuilder.addNode('Tissue', slab),
                             sceneBuilder.addTriangleMesh(TriangleMesh.createCube(float3(8e-3, 3e-3, 8e-3)), tissue))

# The vessel: a closed cylinder whose triangles turn counterclockwise seen from outside (outward normals).
blood = StandardMaterial('Blood')
blood.indexOfRefraction = 1.4
radius, depth, half_length, segments = 2.5e-4, 5e-4, 3.5e-3, 64
vessel = TriangleMesh()
ring = [(math.cos(2 * math.pi * i / segments), math.sin(2 * math.pi * i / segments)) for i in range(segments)]
for x in (-half_length, half_length):
    for c, s in ring:
        vessel.addVertex(float3(x, -depth + radius * c, radius * s), float3(0, c, s), float2(0, 0))
caps = [vessel.addVertex(float3(x, -depth, 0.0), float3(1 if x > 0 else -1, 0, 0), float2(0, 0))
        for x in (-half_length, half_length)]
for i in range(segments):
    j = (i + 1) % segments
    vessel.addTriangle(i, segments + j, segments + i)  # side
    vessel.addTriangle(i, j, segments + j)
    vessel.addTriangle(caps[0], j, i)                    # end caps
    vessel.addTriangle(caps[1], segments + i, segments + j)
sceneBuilder.addMeshInstance(sceneBuilder.addNode('Vessel', Transform()), sceneBuilder.addTriangleMesh(vessel, blood))
"""
Path("lsci_tissue.pyscene").write_text(SCENE)

testbed = falcor.Testbed(create_window=False)
# Keep the two materials apart: they differ only in their names, which identify the media.
testbed.load_scene("lsci_tissue.pyscene", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.resize_frame_buffer(128, 128)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
F_MAX, BINS = 0.016, 1024  # Doppler shifts from -16 to 16 kHz (given in MHz), in bins of 31.25 Hz

graph = testbed.create_render_graph("SpeckleContrastTissue")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera: wide-field illumination.
graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [1.0, 1.0, 1.0],
})
tracer = graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "computeDirect": False,
    "wavelength": 785.0,  # nm
    "frequencyMin": -F_MAX, "frequencyMax": F_MAX, "frequencyBin": BINS,
    "useVolumes": True,
    # Optical properties per meter, typical at 785 nm: tissue with a reduced scattering coefficient mu_s (1 - g) of
    # 1/mm, and blood, which absorbs more. Blood scatters with g near 0.98; g = 0.9 with the same mu_s (1 - g),
    # 1.5/mm, converges much faster.
    "media": {
        "Tissue": {"scattering": [1e4] * 3, "absorption": [20.0] * 3, "anisotropy": 0.9},
        "Blood": {"scattering": [1.5e4] * 3, "absorption": [500.0] * 3, "anisotropy": 0.9},
    },
    # Blood flows along the vessel: a Poiseuille flow of 2 mm/s on its axis (1 mm/s on average).
    "velocities": {
        "Blood": {"flowOrigin": [0.0, -5e-4, 0.0], "flowAxis": [1.0, 0.0, 0.0],
                  "flowRadius": 2.5e-4, "flowMaxSpeed": 2e-3},
    },
    "accumulate": True, "useSingleChannel": True,  # one wavelength: one channel
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.mark_output("Tracer.spectrum")
testbed.render_graph = graph

# 3. Render the spectrum twice
FRAMES = 256  # 256 frames x 64 spp per spectrum
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
intensity = 0.5 * (light_a.sum(0) + light_b.sum(0)).reshape(128, 128)
np.savez("speckle_contrast_tissue.npz", exposures=EXPOSURES, contrast=contrast, intensity=intensity)

# 5. Show the contrast
# The image rows across the vessel (32 um each; the vessel axis is between rows 63 and 64). The scene is the same
# along the vessel, so the contrast of a band of rows is averaged along it.
bands = {"vessel axis": slice(62, 66), "vessel edge": slice(56, 58), "tissue, 0.5 mm away": slice(47, 49),
         "tissue, 1.5 mm away": slice(15, 17)}
shown_exposures = [1e-4, 1e-3, 1e-2]  # s

figure, axes = plt.subplots(1, 5, figsize=(20, 3.9), gridspec_kw={"width_ratios": [1, 1, 1, 1, 1.5]})
image = axes[0].imshow(intensity, cmap="gray", vmin=0, vmax=np.percentile(intensity, 99.5))  # rare bright samples
axes[0].set_title("intensity")
for axis, exposure in zip(axes[1:4], shown_exposures):
    image = axis.imshow(contrast[np.argmin(np.abs(EXPOSURES - exposure))], cmap="magma", vmin=0, vmax=1)
    axis.set_title(f"contrast K, T = {exposure * 1e3:g} ms")
    figure.colorbar(image, ax=axis, fraction=0.046)
for (name, rows), color in zip(bands.items(), ["C0", "C1", "C2", "C3"]):
    for axis in axes[:4]:
        axis.axhline(0.5 * (rows.start + rows.stop) - 0.5, color=color, lw=1, ls=":")
    axes[4].semilogx(EXPOSURES * 1e3, np.nanmean(contrast[:, rows, 16:112], axis=(1, 2)), color=color, label=name)
axes[4].set_xlabel("exposure T (ms)")
axes[4].set_ylim(0, 1.05)
axes[4].set_title("contrast K, averaged along the vessel")
axes[4].legend(loc="lower left")
for axis in axes[:4]:
    axis.set_xticks([])
    axis.set_yticks([])
figure.tight_layout()
figure.savefig("speckle_contrast_tissue.png", dpi=75)
