"""Laser speckle contrast imaging (LSCI) of a vascular network under the surface of tissue: the vessels given as
grids to DopplerHistogramPathTracerInline (set_vessels)."""
# 1. Build the scene
from pathlib import Path

import falcorcomp as falcor
import numpy as np
from scipy.interpolate import CubicSpline
from scipy.spatial import cKDTree
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

# A tissue slab, 8 x 3 x 8 mm with its top face at y = 0, in meters; the camera looks down at a 3 mm wide field.
SCENE = """
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
"""
Path("lsci_network.pyscene").write_text(SCENE)

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("lsci_network.pyscene")
testbed.resize_frame_buffer(256, 256)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the vessel grids
MM, UM = 1e-3, 1e-6
# The network: for each vessel, (x, z) points of its centerline (mm) and its radius there (um), from its parent
# vessel outwards, the way its blood flows. Its axis lies 20 um under the surface plus its radius.
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
    """A smooth centerline through the control points (n, 3), every `spacing`, with its radii interpolated."""
    s = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(control, axis=0), axis=1))])
    t = np.linspace(0.0, s[-1], int(np.ceil(s[-1] / spacing)) + 1)
    return CubicSpline(s, control, bc_type="natural")(t), np.interp(t, s, radii)


def vessel_grids(curves, origin, size, shape):
    """Blood fraction (nz, ny, nx) and velocity (nz, ny, nx, 3) at the cell centers of the box `origin` + [0, size]:
    each cell takes the tube it is deepest in, its fraction falls from 1 to 0 over one cell across the wall, and its
    blood flows along the centerline in a Poiseuille profile, speed(R) (1 - r^2 / R^2)."""
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
    depth = np.where(found, distance - radii[index], np.inf)  # signed distance to each nearby tube's wall
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
BOX_ORIGIN = np.array([-1.8 * MM, -0.2 * MM, -1.8 * MM])  # the top 0.2 mm under the field, in 10 um cells
BOX_SIZE = np.array([3.6 * MM, 0.2 * MM, 3.6 * MM])
fraction, velocity = vessel_grids(curves, BOX_ORIGIN, BOX_SIZE, (360, 20, 360))

# 3. Build the render graph
F_MAX, BINS = 0.032, 1024  # Doppler shifts from -32 to 32 kHz (given in MHz), in bins of 62.5 Hz

graph = testbed.create_render_graph("SpeckleContrastNetwork")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [1.0, 1.0, 1.0],
})
tracer = graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "computeDirect": False,
    "wavelength": 785.0,  # nm
    "frequencyMin": -F_MAX, "frequencyMax": F_MAX, "frequencyBin": BINS,
    "useVolumes": True,
    "media": {"Tissue": {"scattering": [1e4] * 3, "absorption": [20.0] * 3, "anisotropy": 0.9}},  # per meter
    # Perfusion of the tissue by its capillaries, as Brownian motion of its scatterers (m^2/s).
    "velocities": {"Tissue": {"diffusion": 5e-13}},
    "accumulate": True, "useSingleChannel": True,  # one wavelength: one channel
})
# The vessels in the tissue, and the optical properties of blood (per meter) as in the previous tutorial.
tracer.set_vessels("Tissue", fraction, velocity, falcor.float3(*BOX_ORIGIN), falcor.float3(*BOX_SIZE),
                   scattering=falcor.float3(1.5e4, 1.5e4, 1.5e4), absorption=falcor.float3(500.0, 500.0, 500.0),
                   anisotropy=0.9)
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.mark_output("Tracer.spectrum")
testbed.render_graph = graph

# 4. Render the spectrum twice
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

# 5. Compute the speckle contrast
BETA = 1.0  # coherence factor: 1 when a pixel is smaller than a speckle
EXPOSURES = np.logspace(-5, np.log10(5e-3), 31)  # 10 us to 5 ms
lags = np.concatenate([np.arange(BINS), np.arange(-BINS, 0)])  # m, in the order of a length-2B FFT
window = np.sinc(np.outer(EXPOSURES, lags * BIN_MHZ * 1e6)) ** 2  # sinc^2(m df T)
intensity2 = light_a.sum(0, dtype=np.float64) * light_b.sum(0, dtype=np.float64)  # I^2, from the two renders
lit = intensity2 > 0

k2 = np.empty((len(EXPOSURES), intensity2.size))
for start in range(0, intensity2.size, 2048):  # 2048 pixels at a time, to bound the memory
    pixels = slice(start, start + 2048)
    spectrum_a = np.fft.rfft(light_a[:, pixels], 2 * BINS, axis=0)
    spectrum_b = np.fft.rfft(light_b[:, pixels], 2 * BINS, axis=0)
    psd = np.fft.irfft(np.conj(spectrum_a) * spectrum_b, 2 * BINS, axis=0)  # A[m], one factor from each render
    psd = 0.5 * (psd + psd[(-lags) % (2 * BINS)])  # A[m] = A[-m]
    k2[:, pixels] = window @ psd
contrast = np.sqrt(np.clip(BETA * k2 / np.where(lit, intensity2, 1.0), 0.0, None))
contrast[:, ~lit] = np.nan
contrast = contrast.reshape(len(EXPOSURES), 256, 256)
intensity = 0.5 * (light_a.sum(0) + light_b.sum(0)).reshape(256, 256)
np.savez("lsci_network.npz", exposures=EXPOSURES, contrast=contrast, intensity=intensity)

# 6. Show the contrast
# The pixels of each kind of vessel (near its axis) and of the tissue far from them (pixel centers in the field).
pixel = (np.arange(256) + 0.5) / 256 * 3.0 - 1.5  # mm
px, pz = np.meshgrid(pixel, pixel)  # columns along x, rows along z
regions = {"main vessel": [0], "branches": [1, 2], "small vessels": [3, 4, 5, 6]}
nearest = np.full((256, 256), np.inf)  # distance to the nearest vessel wall, mm
masks = {}
for name, members in regions.items():
    inside = np.zeros((256, 256), bool)
    for i in members:
        points, radii = curves[i]
        distance, index = cKDTree(points[:, [0, 2]] / MM).query(np.stack([px, pz], -1).reshape(-1, 2))
        r = radii[index].reshape(256, 256) / MM
        distance = distance.reshape(256, 256)
        inside |= distance < 0.5 * r
        nearest = np.minimum(nearest, distance - r)
    masks[name] = inside
masks["tissue, > 0.2 mm away"] = nearest > 0.2

figure, axes = plt.subplots(1, 5, figsize=(20, 3.9), gridspec_kw={"width_ratios": [1, 1, 1, 1, 1.5]})
axes[0].imshow(fraction.max(axis=1), cmap="gray_r", extent=[-1.8, 1.8, 1.8, -1.8])
axes[0].set_xlim(-1.5, 1.5)
axes[0].set_ylim(1.5, -1.5)
axes[0].set_title("vessels")
axes[1].imshow(intensity, cmap="gray", vmin=0, vmax=np.percentile(intensity, 99.5))  # rare bright samples
axes[1].set_title("intensity")
for axis, exposure in zip(axes[2:4], [1e-3, 5e-3]):
    image = axis.imshow(contrast[np.argmin(np.abs(EXPOSURES - exposure))], cmap="gray", vmin=0, vmax=1)
    axis.set_title(f"contrast K, T = {exposure * 1e3:g} ms")
    figure.colorbar(image, ax=axis, fraction=0.046)
for (name, mask), color in zip(masks.items(), ["C0", "C1", "C2", "C3"]):
    axes[4].semilogx(EXPOSURES * 1e3, np.nanmean(contrast[:, mask], axis=1), color=color, label=name)
axes[4].set_xlabel("exposure T (ms)")
axes[4].set_ylim(0, 1.05)
axes[4].set_title("contrast K, averaged over each kind")
axes[4].legend(loc="lower left")
for axis in axes[:4]:
    axis.set_xticks([])
    axis.set_yticks([])
figure.tight_layout()
figure.savefig("lsci_network.png", dpi=75)
