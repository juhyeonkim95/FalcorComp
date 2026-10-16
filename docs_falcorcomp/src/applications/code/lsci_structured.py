"""Laser speckle contrast imaging (LSCI) under structured illumination: sinusoidal fringes of several spatial
frequencies, demodulated like spatial frequency domain imaging (SFDI), separate a shallow from a deep blood vessel."""
# 1. Build the scene
from pathlib import Path

import falcorcomp as falcor
import numpy as np
from scipy.ndimage import median_filter
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
from mpl_toolkits.mplot3d.art3d import Poly3DCollection

# A tissue slab with two blood vessels that cross at very different depths, made of the materials 'Shallow' and 'Deep':
# a shallow one along x at z = 0.5 mm (radius 0.1 mm, 0.05 to 0.25 mm deep) and a deep one along z at x = 0.4 mm
# (radius 0.3 mm, 0.45 to 1.05 mm deep).
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
shallow = StandardMaterial('Shallow')
shallow.indexOfRefraction = 1.4
deep = StandardMaterial('Deep')
deep.indexOfRefraction = 1.4


def tube(axis, offset, depth, radius, name, material, half_length=3.5e-3, segments=64):
    # A closed cylinder along x or z, its axis `depth` under the surface at `offset` along the other horizontal
    # coordinate; its triangles turn counterclockwise seen from outside.
    mesh = TriangleMesh()
    ring = [(math.cos(2 * math.pi * i / segments), math.sin(2 * math.pi * i / segments)) for i in range(segments)]

    def point(u, c, s):  # along z, or rotated by 90 degrees about y for x
        if axis == 'z':
            return float3(offset + radius * c, -depth + radius * s, u), float3(c, s, 0)
        return float3(u, -depth + radius * s, offset - radius * c), float3(0, s, -c)
    for u in (-half_length, half_length):
        for c, s in ring:
            position, normal = point(u, c, s)
            mesh.addVertex(position, normal, float2(0, 0))
    caps = []
    for u in (-half_length, half_length):
        position, _ = point(u, 0.0, 0.0)
        normal = float3(0, 0, 1 if u > 0 else -1) if axis == 'z' else float3(1 if u > 0 else -1, 0, 0)
        caps.append(mesh.addVertex(position, normal, float2(0, 0)))
    for i in range(segments):
        j = (i + 1) % segments
        mesh.addTriangle(i, segments + j, segments + i)
        mesh.addTriangle(i, j, segments + j)
        mesh.addTriangle(caps[0], j, i)
        mesh.addTriangle(caps[1], segments + i, segments + j)
    sceneBuilder.addMeshInstance(sceneBuilder.addNode(name, Transform()), sceneBuilder.addTriangleMesh(mesh, material))


tube('x', 5e-4, 1.5e-4, 1e-4, 'Shallow', shallow)
tube('z', 4e-4, 7.5e-4, 3e-4, 'Deep', deep)
"""
Path("lsci_structured.pyscene").write_text(SCENE)

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("lsci_structured.pyscene", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.resize_frame_buffer(128, 128)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
F_MAX, BINS = 0.032, 1024  # Doppler shifts from -32 to 32 kHz (given in MHz), in bins of 62.5 Hz
# Scattering with g = 0.7, of reduced coefficients mu_s (1 - g) of 3 per mm in the tissue and 4.5 in the blood: the
# demodulated light is a small part of the light, and a less peaked phase function than g = 0.9 keeps its noise low.
BLOOD = {"scattering": [1.5e4] * 3, "absorption": [500.0] * 3, "anisotropy": 0.7}  # per meter

graph = testbed.create_render_graph("StructuredLSCI")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera; its fringes (patternFrequency, patternPhaseShift) are set for each render below.
light = graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [1.0, 1.0, 1.0],
})
tracer = graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "computeDirect": False,
    "wavelength": 785.0,  # nm
    "frequencyMin": -F_MAX, "frequencyMax": F_MAX, "frequencyBin": BINS,
    "useVolumes": True,
    "media": {"Tissue": {"scattering": [1e4] * 3, "absorption": [20.0] * 3, "anisotropy": 0.7},
              "Shallow": BLOOD, "Deep": BLOOD},
    "velocities": {
        "Tissue": {"diffusion": 1e-13},  # capillary perfusion
        # Poiseuille flows along the vessels, 10 mm/s on their axes
        "Shallow": {"flowOrigin": [0.0, -1.5e-4, 5e-4], "flowAxis": [1.0, 0.0, 0.0], "flowRadius": 1e-4,
                    "flowMaxSpeed": 1e-2},
        "Deep": {"flowOrigin": [4e-4, -7.5e-4, 0.0], "flowAxis": [0.0, 0.0, 1.0], "flowRadius": 3e-4,
                 "flowMaxSpeed": 1e-2},
    },
    "accumulate": True,  # the three color channels hold the three phases of the fringes (step 3)
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.mark_output("Tracer.spectrum")
testbed.render_graph = graph

# 3. Render the spectra under the fringes
FRAMES = 192  # 192 frames x 64 spp per spectrum under uniform light, twice that under fringes
BIN_MHZ = 2 * F_MAX / BINS
HEIGHT = 0.02  # m: the light is 20 mm above the tissue
FREQUENCIES = [0.0, 0.5, 1.0]  # fringes on the tissue, cycles per mm
PHASES = np.array([0.0, 2 * np.pi / 3, 4 * np.pi / 3])


def render(frequency):
    """The light in each bin (bins, pixels, 3) under fringes of `frequency` (cycles per mm on the tissue, along x):
    the three phase-shifted fringes are in the three color channels (patternPhaseShift), so that they come from the
    same paths. A new render with new samples on every call."""
    # patternFrequency is per meter on the plane 1 m from the light: the tissue's frequency times its distance.
    light.set_properties({"patternFrequency": [frequency * 1e3 * HEIGHT, 0.0, 0.0],
                          "patternPhaseShift": PHASES.tolist() if frequency else [0.0, 0.0, 0.0]})
    frames = 2 * FRAMES if frequency else FRAMES  # the demodulated light is noisier
    tracer.reset()
    for _ in range(frames):
        testbed.frame()
    spectrum = graph.get_output("Tracer.spectrum").to_numpy()[..., :3]  # (bins, height, width, channels), per MHz
    return (spectrum / frames * BIN_MHZ).reshape(BINS, -1, 3)


def demodulate(light_per_bin, frequency):
    """The spectrum of the light that keeps the fringes, C = 4/3 sum_j S_j exp(-i phase_j): a complex spectrum whose
    modulus in each bin is the fringes' amplitude (AC). Summed over the phases of the same paths, the uniform part of
    the light cancels path by path. Without fringes, the spectrum of the uniform light (DC)."""
    if not frequency:
        return light_per_bin[..., 0].astype(np.complex128)
    return 4 / 3 * (light_per_bin.astype(np.complex128) * np.exp(-1j * PHASES)).sum(-1)


# 4. Compute the speckle variance
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

# 5. Show the fringes
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

# 6. Show the contrast
# Pixel by pixel, K^2 of the demodulated light is noisy, and a few pixels hold rare bright samples that would dominate a
# sum: the maps take the median of K^2 over 9 x 9 pixels, and the regions the median over their pixels.
pixel = (np.arange(128) + 0.5) / 128 * 3.0 - 1.5  # mm, columns along x, rows along z
px, pz = np.meshgrid(pixel, pixel)
SHALLOW_Z, SHALLOW_DEPTH, SHALLOW_RADIUS = 0.5, 0.15, 0.1  # mm: the shallow vessel, along x
DEEP_X, DEEP_DEPTH, DEEP_RADIUS = 0.4, 0.75, 0.3            # mm: the deep vessel, along z
regions = {"deep vessel": (np.abs(px - DEEP_X) < 0.15) & (np.abs(pz - SHALLOW_Z) > 0.4),  # away from the other
           "shallow vessel": (np.abs(pz - SHALLOW_Z) < 0.05) & ((px < -0.5) | (px > 1.3)),
           "tissue": (px < -0.6) & (np.abs(pz - SHALLOW_Z) > 0.4)}
contrast2 = {frequency: variance[frequency] / intensity2[frequency] for frequency in FREQUENCIES}  # K^2 per pixel
ALL_PIXELS = np.ones((128, 128), bool)


def median_contrast(frequency, mask):
    return np.sqrt(max(np.median(contrast2[frequency][mask]), 0.0))


def lowers(name, keep=ALL_PIXELS):
    """How much the vessel of region `name` lowers K below the tissue's, at each frequency, over the kept pixels."""
    return np.array([1 - median_contrast(frequency, regions[name] & keep) /
                     median_contrast(frequency, regions["tissue"] & keep) for frequency in FREQUENCIES])


def standard_error(statistic, along):
    """The jackknife over 8 bands of 16 rows (along = 0) or columns (along = 1), each left out in turn."""
    bands = np.indices((128, 128))[along] // 16
    values = np.array([statistic(bands != band) for band in range(8)])
    return np.sqrt(7 / 8 * ((values - values.mean(0)) ** 2).sum(0))


k_map = {frequency: np.sqrt(np.clip(median_filter(contrast2[frequency], size=9), 0.0, None))
         for frequency in FREQUENCIES}
k_tissue = {frequency: median_contrast(frequency, regions["tissue"]) for frequency in FREQUENCIES}
SHALLOW, DEEP = "#ff5a1f", "#2f7dff"
figure, axes = plt.subplots(2, 4, figsize=(17, 8.4), gridspec_kw={"width_ratios": [1, 1, 1, 1.3]},
                            layout="constrained")
labels = {frequency: f"fringes {frequency:g} / mm (AC)" if frequency else "uniform light" for frequency in FREQUENCIES}
extent = [-1.5, 1.5, 1.5, -1.5]
for column, frequency in enumerate(FREQUENCIES):
    top = axes[0, column].imshow(k_map[frequency], cmap="gray", vmin=0, vmax=1, extent=extent)
    axes[0, column].set_title(f"K at 5 ms, {labels[frequency]}")
    bottom = axes[1, column].imshow(k_map[frequency] / k_tissue[frequency], cmap="inferno", vmin=0.2, vmax=1.05,
                                    extent=extent)
    axes[1, column].set_title(f"K / K of the tissue, {labels[frequency]}")
axes[1, 0].set_xlabel("x (mm)")
axes[1, 0].set_ylabel("z (mm)")
figure.colorbar(top, ax=axes[0, :3], shrink=0.9)
figure.colorbar(bottom, ax=axes[1, :3], shrink=0.9)
# Across the deep vessel: bands of 8 columns, away from the shallow vessel.
centers = pixel.reshape(16, 8).mean(1)
for frequency, color in zip(FREQUENCIES, ["k", "C0", "C3"]):
    profile = [median_contrast(frequency, (np.abs(px - x) < 1.5 * 8 / 128) & (np.abs(pz - SHALLOW_Z) > 0.4))
               for x in centers]
    axes[0, 3].plot(centers, np.array(profile) / k_tissue[frequency], "o-", ms=3, color=color,
                    label=labels[frequency])
axes[0, 3].axvspan(DEEP_X - DEEP_RADIUS, DEEP_X + DEEP_RADIUS, color=DEEP, alpha=0.12, lw=0)
axes[0, 3].axhline(1.0, color="gray", lw=0.8)
axes[0, 3].set_xlabel("x (mm)")
axes[0, 3].set_ylim(0.6, 1.1)
axes[0, 3].set_title("K / K of the tissue across the deep vessel\n(shaded: its width)")
axes[0, 3].legend(loc="lower left")
# How much of each vessel's dip in K under uniform light the fringes keep, with errors over bands along the vessel.
for name, color, along in [("deep vessel", DEEP, 0), ("shallow vessel", SHALLOW, 1)]:
    def kept(keep, name=name):
        dips = lowers(name, keep)
        return 100 * dips / dips[0]
    axes[1, 3].errorbar(FREQUENCIES, kept(ALL_PIXELS), yerr=standard_error(kept, along), fmt="o-", capsize=4,
                        color=color, label=f"{name} (uniform light: -{100 * lowers(name)[0]:.0f}%)")
axes[1, 3].axhline(100, color="gray", lw=0.8)
axes[1, 3].set_xticks(FREQUENCIES)
axes[1, 3].set_xlabel("fringes (cycles per mm)")
axes[1, 3].set_ylabel("% of the dip under uniform light")
axes[1, 3].set_ylim(-25, 160)
axes[1, 3].set_title("how much of each vessel's dip in K remains")
axes[1, 3].legend(loc="upper left")
figure.savefig("lsci_structured.png", dpi=70)

# 7. Show flow and depth in one image
# Brightness: how much K drops below the tissue's under uniform light (all depths), saturating at 0.3. Color: how much
# of that drop the 1 / mm fringes keep, from the drops' medians over 15 x 15 pixels, as depth varies slowly: all of it
# for shallow flow, none of it for deep flow.
drop = {frequency: np.clip(1 - k_map[frequency] / k_tissue[frequency], 0.0, 1.0) for frequency in FREQUENCIES}
kept = np.clip(median_filter(drop[1.0], size=15) / np.maximum(median_filter(drop[0.0], size=15), 1e-3), 0.0, 1.0)
depth_colors = LinearSegmentedColormap.from_list("depth", [DEEP, "#38e0c8", "#ffd23f", SHALLOW])  # deep -> shallow
flow_and_depth = depth_colors(kept)[..., :3] * np.clip(drop[0.0] / 0.3, 0.0, 1.0)[..., None]

figure = plt.figure(figsize=(18, 6.2))
grid = figure.add_gridspec(1, 3, width_ratios=[1.25, 1, 1.1], left=0.02, right=0.95, bottom=0.1, top=0.88, wspace=0.18)
# The ground truth in 3D, plot axes (x, -z, -depth) in mm, cut at 1.2 mm deep.
axis = figure.add_subplot(grid[0], projection="3d", computed_zorder=False)
axis.set_axis_off()
CUT = 1.2
surface = [[-1.5, -1.5, 0.0], [1.5, -1.5, 0.0], [1.5, 1.5, 0.0], [-1.5, 1.5, 0.0]]
for depth in (0.0, -CUT):
    axis.plot(*(np.array(surface + surface[:1]) + [0.0, 0.0, depth]).T, color="0.55", lw=0.8, zorder=1)
for corner in surface:
    axis.plot([corner[0]] * 2, [corner[1]] * 2, [0.0, -CUT], color="0.55", lw=0.8, zorder=1)
angle, along = np.meshgrid(np.linspace(0, 2 * np.pi, 48), [-1.5, 1.5])
axis.plot_surface(DEEP_X + DEEP_RADIUS * np.cos(angle), -along, -DEEP_DEPTH + DEEP_RADIUS * np.sin(angle), color=DEEP,
                  alpha=0.9, linewidth=0, zorder=2)
# the tissue's surface, translucent: the deep vessel is seen through it, the shallow one lies just under it
axis.add_collection3d(Poly3DCollection([surface], facecolor="0.78", alpha=0.45, zorder=2.5))
axis.plot_surface(along, -(SHALLOW_Z + SHALLOW_RADIUS * np.cos(angle)), -SHALLOW_DEPTH + SHALLOW_RADIUS * np.sin(angle),
                  color=SHALLOW, alpha=0.95, linewidth=0, zorder=3)
for depth in (0.0, 0.5, 1.0):  # a depth scale on the front left edge
    axis.plot([-1.5, -1.62], [-1.5, -1.5], [-depth, -depth], color="0.55", lw=0.8, zorder=1)
    axis.text(-1.7, -1.5, -depth, f"{depth:g}", ha="right", va="center", fontsize="small")
axis.text(-1.9, -1.5, -0.5, "depth\n(mm)", ha="right", va="center", fontsize="small")
for x in (-1.5, 0.0, 1.5):
    axis.text(x, -1.5, -CUT - 0.12, f"{x:g}", ha="center", va="top", fontsize="small")
axis.text(0.75, -1.5, -CUT - 0.35, "x (mm)", ha="center", va="top", fontsize="small")
axis.set_xlim(-1.5, 1.5)
axis.set_ylim(-1.5, 1.5)
axis.set_zlim(-CUT, 0.0)
axis.set_box_aspect((3, 3, CUT), zoom=1.1)
axis.set_proj_type("ortho")
axis.view_init(elev=35, azim=-78)
axis.set_title("ground truth")
axis.legend(handles=[plt.Line2D([], [], color=SHALLOW, lw=6, label="shallow vessel, 0.05-0.25 mm deep"),
                     plt.Line2D([], [], color=DEEP, lw=6, label="deep vessel, 0.45-1.05 mm deep")],
            loc="lower center", bbox_to_anchor=(0.5, -0.06), ncol=2, fontsize="small", frameon=False)
axis = figure.add_subplot(grid[1])
shown = axis.imshow(k_map[0.0], cmap="gray", vmin=0, vmax=1, extent=extent)
axis.set_title("plain LSCI: K at 5 ms, uniform light")
figure.colorbar(shown, ax=axis, shrink=0.8, label="K")
axis.set_xlabel("x (mm)")
axis.set_ylabel("z (mm)")
axis = figure.add_subplot(grid[2])
axis.imshow(flow_and_depth, extent=extent)
axis.set_title("flow and depth: brightness = drop in K,\ncolor = depth (from the 1 / mm fringes)")
legend = figure.colorbar(plt.cm.ScalarMappable(cmap=depth_colors), ax=axis, shrink=0.8, ticks=[0, 1])
legend.ax.set_yticklabels(["deep", "shallow"])
legend.set_label("share of the drop the fringes keep")
axis.set_xlabel("x (mm)")
figure.savefig("lsci_structured_depth.png", dpi=80)
