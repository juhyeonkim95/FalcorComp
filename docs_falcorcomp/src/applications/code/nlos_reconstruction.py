"""Hidden-object reconstruction from time-gated images (scanning NLOS): a dragon out of the camera's view, scanned
voxel by voxel through a relay wall, with four time-gated renderers at equal frame time."""
# 1. Load the scene
import time
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

SIZE = 256
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("nlos-dragon/scene.pyscene")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Plan the scan
ORIGIN = np.array([-1.0, 0.0, 4.0])  # the camera and the laser
TARGET = np.array([0.0, 0.0, 0.0])   # the camera's target on the wall z = 0
TAN_HALF_FOV = 0.5                   # focal length 24 mm, film height 24 mm
GRID = 25                            # voxels along each side of the hidden square: z = 4, 1 x 1 around (2, 0, 4)
LASER_POINTS = 16                    # laser positions per voxel
ELLIPSE_POINTS = 64                  # samples along the detection ellipse
offsets = (np.arange(GRID) + 0.5) / GRID - 0.5
VOXELS = np.array([[2.0 + x, y, 4.0] for y in offsets for x in offsets])  # voxel index = row * GRID + column, +y up
# Column by column, down and up again: consecutive voxels are neighbors.
ORDER = [row * GRID + column for column in range(GRID)
         for row in (range(GRID) if column % 2 == 0 else range(GRID - 1, -1, -1))]


def path_length(voxel):
    """tau, the length laser -> wall -> voxel probed for this voxel: half the gated total."""
    return np.linalg.norm(ORIGIN - TARGET) + np.linalg.norm(TARGET - voxel) + 0.5


def ellipse_on_wall(focus, length, count):
    """count points W of the wall z = 0 with |ORIGIN - W| + |W - focus| = length, at equal angles around the wall
    point where this sum is smallest; each found by bisection along its direction."""
    t = ORIGIN[2] / (ORIGIN[2] + focus[2])
    center = np.array([ORIGIN[0] + t * (focus[0] - ORIGIN[0]), ORIGIN[1] + t * (focus[1] - ORIGIN[1]), 0.0])
    angles = 2.0 * np.pi * np.arange(count) / count
    directions = np.stack([np.cos(angles), np.sin(angles), np.zeros(count)], axis=1)
    near, far = np.zeros(count), np.full(count, length)
    for _ in range(50):
        middle = 0.5 * (near + far)
        points = center + middle[:, None] * directions
        inside = np.linalg.norm(points - ORIGIN, axis=1) + np.linalg.norm(points - focus, axis=1) < length
        near, far = np.where(inside, middle, near), np.where(inside, far, middle)
    return center + near[:, None] * directions


def to_pixels(points):
    """(row, column) pixel coordinates of world points in the camera image."""
    forward = (TARGET - ORIGIN) / np.linalg.norm(TARGET - ORIGIN)
    right = np.cross(forward, [0.0, 1.0, 0.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, forward)
    d = points - ORIGIN
    depth = d @ forward
    return np.stack([(1.0 - d @ up / depth / TAN_HALF_FOV) * SIZE / 2 - 0.5,
                     (d @ right / depth / TAN_HALF_FOV + 1.0) * SIZE / 2 - 0.5], axis=1)


def sample(image, pixels):
    """Bilinear samples of the image at the pixels inside it."""
    row, column = pixels[:, 0], pixels[:, 1]
    inside = (row >= 0) & (row <= SIZE - 1) & (column >= 0) & (column <= SIZE - 1)
    row, column = row[inside], column[inside]
    r0, c0 = np.minimum(row.astype(int), SIZE - 2), np.minimum(column.astype(int), SIZE - 2)
    dr, dc = row - r0, column - c0
    return ((1 - dr) * ((1 - dc) * image[r0, c0] + dc * image[r0, c0 + 1])
            + dr * ((1 - dc) * image[r0 + 1, c0] + dc * image[r0 + 1, c0 + 1]))


# 3. Build a render graph for each renderer
REUSE = {"spatialReuseIteration": 1, "spatialReuseNeighborCount": 3, "spatialReuseGatherRadius": 5.0,
         "useTemporalReuse": True, "temporalHistoryLength": 5.0,
         "isSceneDynamic": True,  # keep the history when the laser moves, re-evaluating its light
         "gaugeMode": "avg_grad", "reconnectionRoughnessThreshold": 0.05}
METHODS = {
    "Path tracing": ("TimeGatedPathTracerInline", {"samplingMethod": "direct"}),
    "Ellipsoidal path tracing": ("TimeGatedPathTracerInline", {"samplingMethod": "ellipsoidal"}),
    "Ellipsoidal + naive reuse": ("TimeGatedReSTIRInline",
                                  {"samplingMethod": "ellipsoidal", **REUSE, "shiftMappingMethod": "no"}),
    "Ellipsoidal + ToF ReSTIR": ("TimeGatedReSTIRInline",
                                 {"samplingMethod": "ellipsoidal", **REUSE, "shiftMappingMethod": "ray_trace"}),
}


def create_graph(method, spp):
    tracer, options = METHODS[method]
    graph = testbed.create_render_graph("NLOS")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserLight", {"laserPosition": ORIGIN.tolist(), "laserDirection": [1.0, 0.0, -4.0],
                                              "laserPower": [100.0, 100.0, 100.0], "laserAngle": 0.0})
    graph.create_pass("Tracer", tracer, {"samplesPerPixel": spp, "maxBounces": 2,
                                         "timeGateMode": "box", "timeGateWindow": 0.01, **options})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser", "Tracer")
    graph.mark_output("Tracer.color")  # one frame per laser position: no accumulation
    return graph


# 4. Render the scan
SHOWN_VOXEL = 12 * GRID + 11  # a voxel on the dragon, whose first frame the figure shows


def scan(method, spp, voxels=ORDER, record=True):
    """Renders the scan with a new graph, so ReSTIR starts with an empty history. Returns the mean frame time in ms
    and, with record, the samples along each voxel's detection ellipse ({voxel: (LASER_POINTS, n)}) and the shown
    voxel's first frame. Timing runs (record=False) read nothing back."""
    graph = create_graph(method, spp)
    testbed.render_graph = graph
    tracer, laser = graph.get_pass("Tracer"), graph.get_pass("Laser")
    times, samples, shown = [], {}, None
    for voxel in voxels:
        tau = path_length(VOXELS[voxel])
        tracer.set_time_gate_info(2.0 * tau, 2.0 * tau, 1)  # the gate: total path length 2 tau
        detection = to_pixels(ellipse_on_wall(VOXELS[voxel], tau, ELLIPSE_POINTS))
        rows = []
        for point in ellipse_on_wall(VOXELS[voxel], tau, LASER_POINTS):
            direction = (point - ORIGIN) / np.linalg.norm(point - ORIGIN)
            laser.update_laser_info(ORIGIN.tolist(), direction.tolist())
            start = time.perf_counter()
            testbed.frame()
            testbed.device.wait()  # include the frame's GPU time
            times.append(time.perf_counter() - start)
            if record:
                image = graph.get_output("Tracer.color").to_numpy()[..., 0]
                rows.append(sample(image, detection))
                if voxel == SHOWN_VOXEL and shown is None:
                    shown = image.copy()
        if record:
            samples[voxel] = np.array(rows)
    return 1000.0 * float(np.mean(times[LASER_POINTS:])), samples, shown  # the first voxel warms up


# 5. Match the frame time: ToF ReSTIR keeps 32 spp, the others are adjusted on the first 50 voxels
SPP = {"Path tracing": 520, "Ellipsoidal path tracing": 54, "Ellipsoidal + naive reuse": 35,
       "Ellipsoidal + ToF ReSTIR": 32}  # equal time on an RTX 3090: the starting points
CALIBRATION, TOLERANCE = ORDER[:50], 0.05
target = scan("Ellipsoidal + ToF ReSTIR", SPP["Ellipsoidal + ToF ReSTIR"], CALIBRATION, record=False)[0]
FRAME_MS = {"Ellipsoidal + ToF ReSTIR": target}
print(f"Ellipsoidal + ToF ReSTIR: {SPP['Ellipsoidal + ToF ReSTIR']} spp, {target:.2f} ms per frame")
for method in ["Path tracing", "Ellipsoidal path tracing", "Ellipsoidal + naive reuse"]:
    trials, spp = {}, SPP[method]
    for attempt in range(4):  # the starting spp, then up to three adjustments
        trials[spp] = scan(method, spp, CALIBRATION, record=False)[0]
        if abs(trials[spp] / target - 1.0) <= TOLERANCE:
            break
        spp = max(1, round(spp * target / trials[spp]))
        if spp in trials:
            break
    SPP[method] = min(trials, key=lambda count: abs(trials[count] - target))
    FRAME_MS[method] = trials[SPP[method]]
    print(f"{method}: {SPP[method]} spp, {FRAME_MS[method]:.2f} ms per frame")

start = time.perf_counter()
results = {method: scan(method, SPP[method]) for method in METHODS}
print(f"4 scans of {len(ORDER)} voxels x {LASER_POINTS} frames in {time.perf_counter() - start:.0f} s")


# 6. Score every voxel
def aggregate(values, power):
    """Geometric mean of the values clipped to [1e-6, 1], to the given power."""
    return float(np.exp(np.mean(np.log(np.clip(values, 1e-6, 1.0)))) ** power)


def score(samples):
    """High when the detection ellipse is lit all along, for every laser position: the geometric mean of the light
    along the ellipse in each frame, then over the frames. A sample without light counts as 1e-6."""
    return aggregate([aggregate(row, 0.7) for row in samples], 0.7)


scores = {method: np.array([score(samples[voxel]) for voxel in range(GRID * GRID)]).reshape(GRID, GRID)
          for method, (_, samples, _) in results.items()}
normalized = {method: values / values.sum() for method, values in scores.items()}  # each sums to 1
for method in METHODS:
    print(f"{method}: score median {np.median(scores[method]):.4f}, max {scores[method].max():.4f}")


# 7. Show a frame and the reconstructions, next to the dragon's outline
def read_vertices(path):
    """Vertex positions of a binary little-endian PLY whose vertex properties are floats."""
    data = Path(path).read_bytes()
    header, body = data.split(b"end_header\n", 1)
    lines = header.decode().splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith("element vertex"))
    count, fields = int(lines[first].split()[2]), 0
    while first + 1 + fields < len(lines) and lines[first + 1 + fields].startswith("property"):
        fields += 1
    return np.frombuffer(body, "<f4", count * fields).reshape(count, fields)[:, :3]


# The dragon's transform in the scene: scaled by 0.1 in z, centered at (2, 0, 4). Its outline on a grid 4 times finer
# than the voxels: the cells that hold a vertex.
vertices = read_vertices("nlos-dragon/meshes/dragon.ply")
FINE = 4
edges = np.linspace(-0.5, 0.5, FINE * GRID + 1)
outline = np.histogram2d(vertices[:, 1], vertices[:, 0], bins=[edges, edges])[0] > 0  # [row (y), column (x)]

fig, axes = plt.subplots(3, len(METHODS) + 1, figsize=(3.2 * (len(METHODS) + 1), 9.9), layout="constrained")
ellipse = to_pixels(ellipse_on_wall(VOXELS[SHOWN_VOXEL], path_length(VOXELS[SHOWN_VOXEL]), 256))
top = np.percentile(results["Ellipsoidal + ToF ReSTIR"][2], 99.5)  # display scale of the frames
raw_top = max(values.max() for values in scores.values())
normalized_top = max(values.max() for values in normalized.values())
for column, (method, (_, _, shown)) in enumerate(results.items()):
    axes[0, column].imshow(np.clip(shown / top, 0, 1) ** (1 / 2.2), cmap="gray")
    axes[0, column].plot(ellipse[:, 1], ellipse[:, 0], "r-", linewidth=0.6)
    axes[0, column].set_title(f"{method}\n{SPP[method]} spp, {FRAME_MS[method]:.1f} ms per frame", fontsize=10)
    axes[1, column].imshow(np.flipud(scores[method]), vmin=0.0, vmax=raw_top, interpolation="nearest")
    axes[1, column].set_title("score", fontsize=10)
    axes[2, column].imshow(np.flipud(normalized[method]), vmin=0.0, vmax=normalized_top, interpolation="nearest")
    axes[2, column].set_title("score / its sum", fontsize=10)
row, column = divmod(SHOWN_VOXEL, GRID)
axes[0, -1].imshow(np.flipud(outline), cmap="gray", interpolation="nearest")
axes[0, -1].add_patch(plt.Rectangle((FINE * column - 0.5, FINE * (GRID - 1 - row) - 0.5), FINE, FINE, fill=False,
                                    edgecolor="red"))
axes[0, -1].set_title("the hidden dragon\n(red: the frames' voxel)", fontsize=10)
for row_index in (1, 2):
    axes[row_index, -1].imshow(np.flipud(outline), cmap="gray", interpolation="nearest")
    axes[row_index, -1].set_title("the hidden dragon", fontsize=10)
for axis in axes.ravel():
    axis.set_xticks([])
    axis.set_yticks([])
fig.savefig("nlos_reconstruction.png", dpi=110)
np.savez("nlos_reconstruction.npz", **{f"{method} score": values for method, values in scores.items()})
