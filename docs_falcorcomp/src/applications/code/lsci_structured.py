"""Laser speckle contrast imaging (LSCI) under structured illumination: sinusoidal fringes of several spatial
frequencies, demodulated like spatial frequency domain imaging (SFDI), separate shallow from deep blood flow."""
# 1. Build the scene
from pathlib import Path

import falcorcomp as falcor
import numpy as np
from scipy.interpolate import CubicSpline
from scipy.ndimage import median_filter
from scipy.spatial import cKDTree
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

# The tissue slab of the vascular network page, with a deep vessel: a cylinder of radius 0.3 mm along z at x = 0.6 mm,
# its axis 1 mm deep (its top two transport lengths deep), made of the material 'Blood'.
SCENE = """
import math
camera = Camera()
camera.position = float3(0.0, 0.02, 0.0)  # 20 mm above the tissue, looking down
camera.target = float3(0.0, 0.0, 0.0)
camera.up = float3(0.0, 0.0, -1.0)
camera.focalLength = 160.0  # mm, on the 24 mm frame: a 3 mm wide field of view
camera.nearPlane = 1e-3     # rays start 1 mm from the camera (the default, 0.1, would pass the tissue)
camera.farPlane = 1.0
sceneBuilder.addCamera(camera)
tissue = StandardMaterial('Tissue')
tissue.indexOfRefraction = 1.4
slab = Transform()
slab.translation = float3(0.0, -1.5e-3, 0.0)
sceneBuilder.addMeshInstance(sceneBuilder.addNode('Tissue', slab),
                             sceneBuilder.addTriangleMesh(TriangleMesh.createCube(float3(8e-3, 3e-3, 8e-3)), tissue))
blood = StandardMaterial('Blood')
blood.indexOfRefraction = 1.4
x0, radius, depth, half_length, segments = 6e-4, 3e-4, 1e-3, 3.5e-3, 64
vessel = TriangleMesh()  # a closed cylinder whose triangles turn counterclockwise seen from outside
ring = [(math.cos(2 * math.pi * i / segments), math.sin(2 * math.pi * i / segments)) for i in range(segments)]
for z in (-half_length, half_length):
    for c, s in ring:
        vessel.addVertex(float3(x0 + radius * c, -depth + radius * s, z), float3(c, s, 0), float2(0, 0))
caps = [vessel.addVertex(float3(x0, -depth, z), float3(0, 0, 1 if z > 0 else -1), float2(0, 0))
        for z in (-half_length, half_length)]
for i in range(segments):
    j = (i + 1) % segments
    vessel.addTriangle(i, segments + j, segments + i)
    vessel.addTriangle(i, j, segments + j)
    vessel.addTriangle(caps[0], j, i)
    vessel.addTriangle(caps[1], segments + i, segments + j)
sceneBuilder.addMeshInstance(sceneBuilder.addNode('Vessel', Transform()), sceneBuilder.addTriangleMesh(vessel, blood))
"""
Path("lsci_structured.pyscene").write_text(SCENE)

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("lsci_structured.pyscene", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.resize_frame_buffer(128, 128)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the superficial vessels as grids, as on the vascular network page
MM, UM = 1e-3, 1e-6
NETWORK = [
    ([(-1.8, -0.5), (-0.9, -0.1), (0.0, 0.05), (0.9, -0.15), (1.8, 0.3)], [60, 58, 55, 52, 50]),
    ([(-0.6, -0.06), (-0.85, 0.5), (-1.25, 1.0), (-1.1, 1.8)], [35, 32, 28, 25]),
    ([(0.55, -0.11), (0.75, -0.65), (0.6, -1.2), (0.95, -1.8)], [35, 32, 28, 25]),
    ([(-0.92, 0.6), (-0.35, 0.95), (0.2, 1.3), (0.5, 1.8)], [20, 18, 16, 15]),
    ([(0.72, -0.75), (1.2, -0.85), (1.8, -0.7)], [20, 18, 15]),
    ([(-0.2, 0.02), (0.05, 0.6), (-0.05, 1.1)], [18, 16, 15]),
    ([(0.64, -1.15), (0.1, -1.4), (-0.6, -1.5), (-1.3, -1.25), (-1.8, -1.35)], [20, 18, 17, 16, 15]),
]


def speed(radius):
    """Blood speed on the axis of a vessel: faster in wider vessels, 2 mm/s at a radius of 20 um."""
    return 2e-3 * radius / (20 * UM)


def smooth_curve(control, radii, spacing):
    s = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(control, axis=0), axis=1))])
    t = np.linspace(0.0, s[-1], int(np.ceil(s[-1] / spacing)) + 1)
    return CubicSpline(s, control, bc_type="natural")(t), np.interp(t, s, radii)


def vessel_grids(curves, origin, size, shape):
    """Blood fraction (nz, ny, nx) and velocity (nz, ny, nx, 3) of the tubes along `curves` (see the vascular network
    page)."""
    points = np.concatenate([p for p, _ in curves])
    radii = np.concatenate([r for _, r in curves])
    tangents = np.concatenate([np.gradient(p, axis=0) for p, _ in curves])
    tangents /= np.linalg.norm(tangents, axis=1, keepdims=True)
    nz, ny, nx = shape
    cell = size / np.array([nx, ny, nz])
    x, y, z = [origin[i] + (np.arange(n) + 0.5) * cell[i] for i, n in enumerate((nx, ny, nz))]
    centers = np.stack(np.meshgrid(x, y, z, indexing="ij"), -1).transpose(2, 1, 0, 3).reshape(-1, 3)
    distance, index = cKDTree(points).query(centers, k=8, distance_upper_bound=radii.max() + 2 * cell.max())
    found = index < len(points)
    index = np.where(found, index, 0)
    depth = np.where(found, distance - radii[index], np.inf)
    best = np.argmin(depth, axis=1)
    rows = np.arange(len(centers))
    depth, nearest, r = depth[rows, best], index[rows, best], distance[rows, best]
    fraction = np.clip(0.5 - depth / cell.min(), 0.0, 1.0)
    profile = np.where(np.isfinite(depth), np.clip(1.0 - (r / radii[nearest]) ** 2, 0.0, None), 0.0)
    velocity = (speed(radii[nearest]) * profile)[:, None] * tangents[nearest]
    return fraction.reshape(nz, ny, nx).astype(np.float32), velocity.reshape(nz, ny, nx, 3).astype(np.float32)


curves = []
for xz, radii in NETWORK:
    radii = np.array(radii) * UM
    control = np.array([(x * MM, -(20 * UM + r), z * MM) for (x, z), r in zip(xz, radii)])
    curves.append(smooth_curve(control, radii, 2 * UM))
BOX_ORIGIN = np.array([-1.8 * MM, -0.2 * MM, -1.8 * MM])
BOX_SIZE = np.array([3.6 * MM, 0.2 * MM, 3.6 * MM])
fraction, velocity = vessel_grids(curves, BOX_ORIGIN, BOX_SIZE, (360, 20, 360))

# 3. Build the render graph
F_MAX, BINS = 0.032, 1024  # Doppler shifts from -32 to 32 kHz (given in MHz), in bins of 62.5 Hz
# Scattering with g = 0.7, of reduced coefficients mu_s (1 - g) of 3 per mm in the tissue and 4.5 in the blood: the
# demodulated light is a small part of the light, and a less peaked phase function than g = 0.9 keeps its noise low.
BLOOD = {"scattering": [1.5e4] * 3, "absorption": [500.0] * 3, "anisotropy": 0.7}  # per meter

graph = testbed.create_render_graph("StructuredLSCI")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera; its fringes (patternFrequency, patternPhase) are set for each render below.
light = graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [1.0, 1.0, 1.0],
})
tracer = graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "computeDirect": False,
    "wavelength": 785.0,  # nm
    "frequencyMin": -F_MAX, "frequencyMax": F_MAX, "frequencyBin": BINS,
    "useVolumes": True,
    "media": {"Tissue": {"scattering": [1e4] * 3, "absorption": [20.0] * 3, "anisotropy": 0.7}, "Blood": BLOOD},
    "velocities": {
        "Tissue": {"diffusion": 1e-13},  # capillary perfusion
        "Blood": {"flowOrigin": [6e-4, -1e-3, 0.0], "flowAxis": [0.0, 0.0, 1.0], "flowRadius": 3e-4,
                  "flowMaxSpeed": 1e-2},  # the deep vessel
    },
    "accumulate": True,  # the three color channels hold the three phases of the fringes (step 4)
})
tracer.set_vessels("Tissue", fraction, velocity, falcor.float3(*BOX_ORIGIN), falcor.float3(*BOX_SIZE),
                   scattering=falcor.float3(*BLOOD["scattering"]), absorption=falcor.float3(*BLOOD["absorption"]),
                   anisotropy=BLOOD["anisotropy"])
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.mark_output("Tracer.spectrum")
testbed.render_graph = graph

# 4. Render the spectra under the fringes
FRAMES = 192  # 192 frames x 64 spp per spectrum
BIN_MHZ = 2 * F_MAX / BINS
HEIGHT = 0.02  # m: the light is 20 mm above the tissue
FREQUENCIES = [0.0, 0.3, 0.6]  # fringes on the tissue, cycles per mm
PHASES = np.array([0.0, 2 * np.pi / 3, 4 * np.pi / 3])


def render(frequency):
    """The light in each bin (bins, pixels, 3) under fringes of `frequency` (cycles per mm on the tissue, along x):
    the three phase-shifted fringes are in the three color channels (patternPhaseShift), so that they come from the
    same paths. A new render with new samples on every call."""
    # patternFrequency is per meter on the plane 1 m from the light: the tissue's frequency times its distance.
    light.set_properties({"patternFrequency": [frequency * 1e3 * HEIGHT, 0.0, 0.0],
                          "patternPhaseShift": PHASES.tolist() if frequency else [0.0, 0.0, 0.0]})
    tracer.reset()
    for _ in range(FRAMES):
        testbed.frame()
    spectrum = graph.get_output("Tracer.spectrum").to_numpy()[..., :3]  # (bins, height, width, channels), per MHz
    return (spectrum / FRAMES * BIN_MHZ).reshape(BINS, -1, 3)


def demodulate(light_per_bin, frequency):
    """The spectrum of the light that keeps the fringes, C = 4/3 sum_j S_j exp(-i phase_j): a complex spectrum whose
    modulus in each bin is the fringes' amplitude (AC). Summed over the phases of the same paths, the uniform part of
    the light cancels path by path. Without fringes, the spectrum of the uniform light (DC)."""
    if not frequency:
        return light_per_bin[..., 0].astype(np.complex128)
    return 4 / 3 * (light_per_bin.astype(np.complex128) * np.exp(-1j * PHASES)).sum(-1)


# 5. Compute the speckle variance
EXPOSURE = 5e-3  # s
lags = np.concatenate([np.arange(BINS), np.arange(-BINS, 0)])  # m, in the order of a length-2B FFT
window = np.sinc(lags * BIN_MHZ * 1e6 * EXPOSURE) ** 2  # sinc^2(m df T)


def speckle_variance(c_a, c_b):
    """For the light of the spectra c_a and c_b (two independent renders, real or complex): its speckle variance over
    the exposure, sum_m A[m] sinc^2(m df T) with A[m] = Re sum_k conj(c_a[k]) c_b[k + m], and its intensity squared,
    per pixel. K^2 is their ratio."""
    intensity2 = (np.conj(c_a.sum(0)) * c_b.sum(0)).real
    variance = np.empty(intensity2.size)
    for start in range(0, intensity2.size, 2048):  # 2048 pixels at a time, to bound the memory
        pixels = slice(start, start + 2048)
        correlation = np.fft.ifft(np.conj(np.fft.fft(c_a[:, pixels], 2 * BINS, axis=0)) *
                                  np.fft.fft(c_b[:, pixels], 2 * BINS, axis=0), axis=0).real
        correlation = 0.5 * (correlation + correlation[(-lags) % (2 * BINS)])  # A[m] = A[-m]
        variance[pixels] = window @ correlation
    return variance.reshape(128, 128), intensity2.reshape(128, 128)


def contrast(variance, intensity2):
    return np.sqrt(np.clip(variance / intensity2, 0.0, None))


images, phase_contrast = {}, {}  # what the camera sees under the three phases: the image and its K (height, width, 3)
variance, intensity2 = {}, {}  # of the demodulated light
for frequency in FREQUENCIES:
    light_a, light_b = render(frequency), render(frequency)  # two independent renders
    images[frequency] = 0.5 * (light_a.sum(0) + light_b.sum(0)).reshape(128, 128, 3)
    phase_contrast[frequency] = np.stack([contrast(*speckle_variance(light_a[..., j], light_b[..., j]))
                                          for j in range(3)], -1)
    variance[frequency], intensity2[frequency] = speckle_variance(demodulate(light_a, frequency),
                                                                  demodulate(light_b, frequency))
    del light_a, light_b
np.savez("lsci_structured.npz", frequencies=FREQUENCIES, variance=np.array([variance[f] for f in FREQUENCIES]),
         intensity2=np.array([intensity2[f] for f in FREQUENCIES]), images=np.array([images[f] for f in FREQUENCIES]),
         phase_contrast=np.array([phase_contrast[f] for f in FREQUENCIES]))

# 6. Show the fringes
# What the camera sees under the three phases: the image (the spectra summed over their bins), median filtered (3 x 3)
# for display as it has rare bright samples, and its speckle contrast at 5 ms, pixel by pixel.
figure, axes = plt.subplots(4, 4, figsize=(12, 12.4))
for (image_row, contrast_row), frequency in zip([axes[0:2], axes[2:4]], FREQUENCIES[1:]):
    image = np.stack([median_filter(images[frequency][..., j], size=3) for j in range(3)], -1)
    top = np.percentile(image, 99.5)
    for j, phase in enumerate(np.degrees(PHASES)):
        image_row[j].imshow(image[..., j], cmap="gray", vmin=0, vmax=top)
        image_row[j].set_title(f"{frequency:g} / mm, phase {phase:.0f}°")
        contrast_row[j].imshow(phase_contrast[frequency][..., j], cmap="gray", vmin=0, vmax=1)
        contrast_row[j].set_title(f"K at 5 ms, phase {phase:.0f}°")
    image_row[3].imshow(image.mean(-1), cmap="gray", vmin=0, vmax=top)
    image_row[3].set_title("DC: mean of the three")
    contrast_row[3].imshow(contrast(variance[0.0], intensity2[0.0]), cmap="gray", vmin=0, vmax=1)
    contrast_row[3].set_title("K at 5 ms, uniform light")
for axis in axes.ravel():
    axis.set_xticks([])
    axis.set_yticks([])
figure.tight_layout()
figure.savefig("lsci_structured_fringes.png", dpi=75)

# 7. Show the contrast
pixel = (np.arange(128) + 0.5) / 128 * 3.0 - 1.5  # mm, columns along x, rows along z
px, pz = np.meshgrid(pixel, pixel)
superficial = np.full((128, 128), np.inf)  # distance to the nearest superficial vessel wall, mm
for points, radii in curves:
    distance, index = cKDTree(points[:, [0, 2]] / MM).query(np.stack([px, pz], -1).reshape(-1, 2))
    superficial = np.minimum(superficial, (distance - radii[index] / MM).reshape(128, 128))
regions = {"deep vessel": (np.abs(px - 0.6) < 0.2) & (superficial > 0.15),  # over it, away from the others
           "superficial vessels": (superficial < -0.02) & (np.abs(px - 0.6) > 0.6),
           "tissue": (np.abs(px - 0.6) > 1.0) & (superficial > 0.15)}


def pooled(frequency, mask, axis=None, bins=None):
    """K from the speckle variance and the intensity squared summed over the pixels of `mask` (in `bins` bins of the
    other axis when given): the demodulated light is too noisy for K pixel by pixel."""
    def total(values):
        values = np.where(mask, values, 0.0)
        return values.sum() if axis is None else values.sum(axis).reshape(bins, -1).sum(1)
    return np.sqrt(np.clip(total(variance[frequency]) / total(intensity2[frequency]), 0.0, None))


figure, axes = plt.subplots(1, 3, figsize=(16, 4.4), gridspec_kw={"width_ratios": [1, 1.4, 1.2]})
axes[0].imshow(contrast(variance[0.0], intensity2[0.0]), cmap="gray", vmin=0, vmax=1, extent=[-1.5, 1.5, 1.5, -1.5])
axes[0].axvline(0.6, color="C1", ls="--", lw=1)
axes[0].set_title("K at 5 ms, uniform light\n(dashed: the deep vessel, 1 mm under)")
axes[0].set_xlabel("x (mm)")
axes[0].set_ylabel("z (mm)")
labels = {frequency: f"fringes {frequency:g} / mm (AC)" if frequency else "uniform light" for frequency in FREQUENCIES}
for frequency, color in zip(FREQUENCIES, ["k", "C0", "C3"]):
    # Across the deep vessel: each column, away from the superficial vessels, in bins of 8 columns.
    axes[1].plot(pixel.reshape(16, 8).mean(1), pooled(frequency, superficial > 0.15, 0, 16), color=color,
                 label=labels[frequency])
axes[1].axvline(0.6, color="C1", ls="--", lw=1)
axes[1].set_xlabel("x (mm)")
axes[1].set_ylim(0, 1)
axes[1].set_title("K at 5 ms across the deep vessel")
axes[1].legend(loc="lower left")
for name, color in [("deep vessel", "C1"), ("superficial vessels", "C2")]:
    ratio = [pooled(f, regions[name]) / pooled(f, regions["tissue"]) for f in FREQUENCIES]
    axes[2].plot(FREQUENCIES, ratio, "o-", color=color, label=f"over the {name}")
axes[2].axhline(1.0, color="gray", lw=0.8)
axes[2].set_xlabel("fringes (cycles per mm)")
axes[2].set_ylabel("K / K over the tissue")
axes[2].set_title("contrast relative to the tissue, at 5 ms")
axes[2].set_ylim(0, 1.05)
axes[2].legend(loc="center right")
figure.tight_layout()
figure.savefig("lsci_structured.png", dpi=75)
