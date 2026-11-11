"""Navigation around a corner from transient histograms: a car with a lidar (a camera and a laser at the camera) drives
toward a corner; a box stands out of sight around it. A small network, trained on clean renders, estimates where the box
is from every frame's transient histogram, and the car plans its path around it. Path tracing, naive reuse and
ToF ReSTIR render the drive."""
# 1. Build the scene
import heapq
import shutil
import subprocess
import tempfile
import time
from collections import deque
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import torch
import torch.nn.functional as F
from scipy.interpolate import splev, splprep
import falcorcomp as falcor

# A floor, a building over x, z in [0.2, 1.2] (a unit cube) at the corner of a road of width 0.4 that runs along -z and
# turns to +x, and a box 0.05 x 0.5 x 0.2. An animation moves the box with the clock: at time t its center is at
# (t, 0, 0) (the keyframes replace the node's transform), so half of it is below the floor.
SCENE = """
camera = Camera()
camera.position = float3(0, 0.2, 1)
camera.target = float3(0, 0.2, 0)
camera.up = float3(0, 1, 0)
camera.focalLength = 48
sceneBuilder.addCamera(camera)

Diffuse = StandardMaterial('Diffuse')
Diffuse.baseColor = float4(1.0, 1.0, 1.0, 1)
Diffuse.roughness = 1

sceneBuilder.addMeshInstance(
    sceneBuilder.addNode('Floor', Transform(scaling=float3(2.0, 2.0, 2.0))),
    sceneBuilder.addTriangleMesh(TriangleMesh.createQuad(), Diffuse)
)
width = 0.2
sceneBuilder.addMeshInstance(
    sceneBuilder.addNode('Corner', Transform(translation=float3(0.5 + width, 0.5, 0.5 + width))),
    sceneBuilder.addTriangleMesh(TriangleMesh.createCube(), Diffuse)
)
ObjNodeId = sceneBuilder.addNode('Object', Transform(translation=float3(0.0, 0.25, 0.05)))
sceneBuilder.addMeshInstance(ObjNodeId, sceneBuilder.addTriangleMesh(TriangleMesh.createCube(float3(0.05, 0.5, width)), Diffuse))
anim = Animation('ObjAnimation', ObjNodeId, 18)
for t in [0, 1]:
    ObjTransform = Transform()
    ObjTransform.translation = float3(t, 0, 0.0)
    anim.addKeyframe(t, ObjTransform)
sceneBuilder.addAnimation(anim)
"""
Path("nlos_navigation.pyscene").write_text(SCENE)

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("nlos_navigation.pyscene")
testbed.resize_frame_buffer(64, 64)
testbed.clock.pause()

PITCH = np.deg2rad(10.0)                                  # the lidar looks 10 degrees down the road
DIRECTION = np.array([0.0, -np.sin(PITCH), -np.cos(PITCH)])


def place(camera_z, box_x):
    """The car at z = camera_z on the road's center line (lidar height 0.2), the box at x = box_x (the clock)."""
    position = np.array([0.0, 0.2, camera_z])
    testbed.scene.camera.position = position.tolist()
    testbed.scene.camera.target = (position + DIRECTION).tolist()
    testbed.clock.time = float(box_x)
    return position, position + DIRECTION


# 2. Build a render graph for each renderer
HISTOGRAM = {"timeMin": 3.0, "timeMax": 4.28, "timeBin": 64,  # 64 bins of 0.02 in path length
             "timeGateMode": "box", "maxBounces": 3, "useSingleChannel": True}
# Temporal reuse only: every bin resamples the same bin of the previous frame. The laser moves with the car, so
# isSceneDynamic keeps the history and re-lights its paths with the laser of the current frame.
REUSE = {"useTemporalReuse": True, "temporalHistoryLength": 5.0, "isSceneDynamic": True, "spatialReuseIteration": 0,
         "reconnectionRoughnessThreshold": 0.05, "NewtonMaxIteration": 5}
METHODS = {
    "Path tracing": ("TransientHistogramPathTracerInline", {"samplesPerPixel": 768}),
    "Naive reuse": ("TransientHistogramReSTIRInline", {**REUSE, "samplesPerPixel": 550, "shiftMappingMethod": "no"}),
    "ToF ReSTIR": ("TransientHistogramReSTIRInline", {**REUSE, "samplesPerPixel": 440,
                                                      "shiftMappingMethod": "area_adaptive", "gaugeMode": "avg_grad"}),
}
CLEAN = ("TransientHistogramPathTracerInline", {"samplesPerPixel": 4096, "accumulate": True})  # x 16 frames


def create_graph(tracer, properties):
    graph = testbed.create_render_graph("Navigation")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True})
    # The laser is at the camera, aimed where it looks, with a beam of 5 degrees.
    graph.create_pass("Laser", "LaserLight", {"laserCollocated": True, "laserAngle": 5.0,
                                              "laserPower": [100.0, 100.0, 100.0]})
    graph.create_pass("Tracer", tracer, {**HISTOGRAM, **properties})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser", "Tracer")
    graph.mark_output("Tracer.histogram")
    testbed.render_graph = graph
    return graph


def render_clean(graph, frames=16):
    """The mean of `frames` frames of 4096 samples per pixel: 65,536 in all."""
    testbed.frame()  # the sum restarts after a new graph's first frame and after a camera move: skip one frame
    graph.get_pass("Tracer").reset()
    for _ in range(frames):
        testbed.frame()
    return graph.get_output("Tracer.histogram").to_numpy() / frames  # (bins, rows, columns)


# 3. Render clean histograms for training: random car and box positions
TRAINING = Path("training.npz")  # rendered below if missing
if not TRAINING.exists():
    rng = np.random.default_rng(0)
    graph = create_graph(*CLEAN)
    start, histograms, cameras = time.perf_counter(), [], []
    for _ in range(1024):
        camera_z = 0.5 + 0.5 * rng.random()
        box_x = 0.3 + 0.3 * rng.random()
        cameras.append(place(camera_z, box_x) + (box_x,))
        histograms.append(render_clean(graph))
    positions, targets, boxes = map(np.array, zip(*cameras))
    np.savez_compressed(TRAINING, histograms=np.array(histograms), positions=positions, targets=targets, boxes=boxes)
    print(f"1024 training histograms in {time.perf_counter() - start:.0f} s")
training = np.load(TRAINING)


# 4. Train the network: histogram, car position and target -> box position
class HistogramToPosition(torch.nn.Module):
    def __init__(self, bins):
        super().__init__()
        self.conv1 = torch.nn.Conv2d(bins, 32, 3, padding=1)  # the bins are the input channels
        self.conv2 = torch.nn.Conv2d(32, 64, 3, padding=1)
        self.pool = torch.nn.AdaptiveAvgPool2d((4, 4))
        self.fc1 = torch.nn.Linear(64 * 4 * 4 + 3 + 3, 128)
        self.fc2 = torch.nn.Linear(128, 2)  # the box's x, and a second output trained to 0

    def forward(self, histogram, position, target):
        x = self.pool(F.relu(self.conv2(F.relu(self.conv1(histogram))))).flatten(1)
        x = F.relu(self.fc1(torch.cat([x, position, target], 1)))
        return self.fc2(x)


device = "cuda" if torch.cuda.is_available() else "cpu"
torch.manual_seed(0)
tensor = lambda array: torch.tensor(np.asarray(array), dtype=torch.float32, device=device)  # noqa: E731
histograms, positions, targets = tensor(training["histograms"]), tensor(training["positions"]), tensor(training["targets"])
labels = torch.stack([tensor(training["boxes"]), torch.zeros(len(training["boxes"]), device=device)], 1)
model = HistogramToPosition(histograms.shape[1]).to(device)
optimizer = torch.optim.Adam(model.parameters(), lr=1e-5)
start = time.perf_counter()
for epoch in range(500):
    for batch in torch.randperm(len(labels), device=device).split(32):
        loss = F.l1_loss(model(histograms[batch], positions[batch], targets[batch]), labels[batch])
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
model.eval()
print(f"Trained in {time.perf_counter() - start:.0f} s, last batch L1 {loss.item():.5f}")


def estimate(histogram, position, target):
    with torch.no_grad():
        return float(model(tensor(histogram[None]), tensor(position[None]), tensor(target[None]))[0, 0])


# 5. Drive: 100 frames toward the corner, 0.005 per frame, the box at x = 0.4
BOX_X = 0.4
DRIVE = 1.0 - 0.005 * np.arange(100)  # the car's z in every frame


def drive(tracer, properties, record=True):
    """Renders the drive with a new graph; returns the mean frame time in ms and, with record, every frame's histogram.
    Timing runs (record=False) read nothing back."""
    graph = create_graph(tracer, properties)
    times, frames = [], []
    for z in DRIVE:
        place(z, BOX_X)
        start = time.perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        times.append(time.perf_counter() - start)
        if record:
            frames.append(graph.get_output("Tracer.histogram").to_numpy())
    return 1000.0 * float(np.mean(times[10:])), frames  # the first frames compile shaders


FRAME_MS = {name: drive(*METHODS[name], record=False)[0] for name in METHODS}
renders = {name: drive(*METHODS[name])[1] for name in METHODS}
for name in METHODS:
    print(f"{name}: {METHODS[name][1]['samplesPerPixel']} spp, {FRAME_MS[name]:.2f} ms per frame")
graph = create_graph(*CLEAN)
renders["Clean render"] = []
for z in DRIVE:
    place(z, BOX_X)
    renders["Clean render"].append(render_clean(graph))

# 6. Estimate the box's position in every frame
NAMES = ["Clean render", "Path tracing", "Naive reuse", "ToF ReSTIR"]
estimates = {name: np.array([estimate(h, *place(z, BOX_X)) for h, z in zip(renders[name], DRIVE)]) for name in NAMES}
for name in NAMES:
    print(f"{name}: box at x = {np.mean(estimates[name][50:]):.4f} (frames 50 to 99; true {BOX_X})")
STYLE = {"Clean render": dict(color="black", alpha=0.3), "Path tracing": dict(color="C0"),
         "Naive reuse": dict(color="C1"), "ToF ReSTIR": dict(color="C2")}
fig, axis = plt.subplots(figsize=(8, 4))
for name in NAMES:  # from frame 20 on: the reuse renderers start without history
    axis.plot(np.arange(20, 100), estimates[name][20:], linewidth=2, label=name, **STYLE[name])
axis.axhline(BOX_X, color="red", linestyle="--", label="the box")
axis.set_xlabel("frame")
axis.set_ylabel("estimated box position x")
axis.grid(True, alpha=0.2)
axis.legend(ncol=5, fontsize=8)
fig.tight_layout()
fig.savefig("nlos_navigation_estimates.png", dpi=200)


# 7. Plan the path around the box: A* on the road, then shortcuts and a spline
CELL, ROAD_HALF_WIDTH, BOX_MARGIN, WALL_MARGIN = 0.01, 0.2, 0.01, 0.02
BOX_Z, BOX_SIZE = 0.05, (0.05, 0.2)  # the footprint the planner avoids: centered at (x, 0.05), in the inner lane
xs = zs = np.arange(-1.0, 1.0 + 1e-12, CELL)
X, Z = np.meshgrid(xs, zs)  # [z index, x index]
# Distance to the road's center line, (0, 1) -> (0, 0) -> (1, 0); the road is within 0.2 of it.
CENTER = np.minimum(np.hypot(X, Z - np.clip(Z, 0, 1)), np.hypot(X - np.clip(X, 0, 1), Z))
ROAD = CENTER <= ROAD_HALF_WIDTH
NEIGHBORS = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]


def distance_in_cells(sources):
    """Breadth-first distance, in cells (8-connected steps), to the nearest True cell."""
    distance = np.full(sources.shape, np.inf)
    queue = deque(zip(*np.nonzero(sources)))
    distance[sources] = 0
    while queue:
        z, x = queue.popleft()
        for dz, dx in NEIGHBORS:
            if 0 <= z + dz < distance.shape[0] and 0 <= x + dx < distance.shape[1] and distance[z + dz, x + dx] > distance[z, x] + 1:
                distance[z + dz, x + dx] = distance[z, x] + 1
                queue.append((z + dz, x + dx))
    return distance


NEAR_WALL = distance_in_cells(~ROAD) <= np.ceil(WALL_MARGIN / CELL)


def cell_of(x, z):
    return int(round((z - zs[0]) / CELL)), int(round((x - xs[0]) / CELL))


def segment_free(p, q, free):
    for t in np.linspace(0.0, 1.0, max(2, int(np.ceil(np.linalg.norm(q - p) / (CELL / 2))))):
        if not free[cell_of(*(p + t * (q - p)))]:
            return False
    return True


def plan(box_x):
    """The path from (0, 0.51) to (1, 0) around the footprint at x = box_x."""
    box = (np.abs(X - box_x) <= BOX_SIZE[0] / 2) & (np.abs(Z - BOX_Z) <= BOX_SIZE[1] / 2)
    free = ROAD & ~NEAR_WALL & ~(distance_in_cells(box) <= np.ceil(BOX_MARGIN / CELL))
    start, goal = cell_of(0.0, 0.51), cell_of(1.0, 0.0)
    queue, came, best = [(0.0, start)], {}, {start: 0.0}
    while queue:
        _, cell = heapq.heappop(queue)
        if cell == goal:
            break
        for dz, dx in NEIGHBORS:
            nz, nx = cell[0] + dz, cell[1] + dx
            if 0 <= nz < len(zs) and 0 <= nx < len(xs) and free[nz, nx]:
                # A step costs more away from the center line.
                g = best[cell] + np.hypot(dz, dx) * (1.0 + 4.0 * min(CENTER[nz, nx] / ROAD_HALF_WIDTH, 1.0) ** 2)
                if g < best.get((nz, nx), np.inf):
                    best[(nz, nx)], came[(nz, nx)] = g, cell
                    heapq.heappush(queue, (g + np.hypot(goal[0] - nz, goal[1] - nx), (nz, nx)))
    cells = [goal]
    while cells[-1] in came:
        cells.append(came[cells[-1]])
    path = [np.array([xs[x], zs[z]]) for z, x in cells[::-1]]
    rng = np.random.default_rng(0)
    for _ in range(500):  # shortcuts: drop the vertices between two that see each other
        if len(path) <= 2:
            break
        i = int(rng.integers(0, len(path) - 2))
        j = int(rng.integers(i + 2, len(path)))
        if segment_free(path[i], path[j], free):
            path = path[:i + 1] + path[j:]
    path = np.array(path)
    lengths = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))])
    dense = np.array([np.interp(np.linspace(0, lengths[-1], int(lengths[-1] / 0.02) + 2), lengths, path[:, k])
                      for k in range(2)]).T
    spline, _ = splprep(dense.T, s=0.001, k=3)
    return np.stack(splev(np.linspace(0.0, 1.0, 500), spline), axis=1)


plans = {name: plan(np.mean(estimates[name][50:])) for name in NAMES}

# 8. Show the histograms and the planned paths
SHOWN_FRAME, SHOWN_BINS = 50, list(range(0, 64, 8))  # 8 of the 64 bins of frame 50
fig, axes = plt.subplots(len(NAMES), len(SHOWN_BINS), figsize=(13, 7), layout="constrained")
for row, name in enumerate(NAMES):
    for column, b in enumerate(SHOWN_BINS):
        top = np.percentile(renders["Clean render"][SHOWN_FRAME][b], 99.5) + 1e-12  # each bin on its own scale
        axes[row, column].imshow(np.clip(renders[name][SHOWN_FRAME][b] / top, 0, 1) ** (1 / 2.2), cmap="gray")
        axes[row, column].set_xticks([])
        axes[row, column].set_yticks([])
        if row == 0:
            axes[row, column].set_title(f"bin {b} (path length {3.0 + 0.02 * (b + 0.5):.2f})", fontsize=8)
    spp = "65,536 spp" if name == "Clean render" else f"{METHODS[name][1]['samplesPerPixel']} spp, {FRAME_MS[name]:.1f} ms"
    axes[row, 0].set_ylabel(f"{name}\n{spp}", fontsize=9)
fig.savefig("nlos_navigation_histograms.png", dpi=110)

fig, axis = plt.subplots(figsize=(6, 6))
axis.imshow(ROAD.astype(float), extent=[xs[0], xs[-1], zs[0], zs[-1]], origin="lower", alpha=0.18)
footprint = lambda x: (x - BOX_SIZE[0] / 2, BOX_Z - BOX_SIZE[1] / 2)  # noqa: E731
axis.add_patch(plt.Rectangle(footprint(BOX_X), *BOX_SIZE, fill=False, color="red", linewidth=3))  # the true position
for name in NAMES[1:]:
    box_x = np.mean(estimates[name][50:])
    axis.add_patch(plt.Rectangle(footprint(box_x), *BOX_SIZE, fill=False, linestyle="--", linewidth=2, alpha=0.6,
                                 color=STYLE[name]["color"]))
    axis.plot(*plans[name].T, linewidth=2, color=STYLE[name]["color"], label=f"{name} (box at {box_x:.3f})")
axis.scatter([0.0], [0.51], s=90)
axis.set_xlim(-0.05, 0.5)
axis.set_ylim(0.55, -0.1)  # the car comes from below
axis.set_aspect("equal")
axis.set_xticks([])
axis.set_yticks([])
axis.legend(fontsize=8, loc="lower right")
fig.tight_layout()
fig.savefig("nlos_navigation_paths.png", dpi=200)


# A video of the transient histograms at frame 50, bin by bin, one panel per renderer
def save_video(path, frame, fps=10):
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        print("ffmpeg not found: no video")
        return
    with tempfile.TemporaryDirectory() as folder:
        for b in range(HISTOGRAM["timeBin"]):
            figure, axes = plt.subplots(1, 4, figsize=(10, 2.9))
            scale = np.percentile(renders["Clean render"][frame][b], 99.5) + 1e-12
            for axis, name in zip(axes, NAMES):
                axis.imshow(np.clip(renders[name][frame][b] / scale, 0, 1) ** (1 / 2.2), cmap="gray")
                axis.set_title(name, fontsize=10)
                axis.axis("off")
            figure.suptitle(f"path length {3.0 + 0.02 * (b + 0.5):.2f}", fontsize=10)
            figure.savefig(f"{folder}/bin_{b:03d}.png", dpi=100)
            plt.close(figure)
        subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-framerate", str(fps), "-i", f"{folder}/bin_%03d.png",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", path],
                       check=True)


save_video("nlos_navigation_histograms.mp4", SHOWN_FRAME)
