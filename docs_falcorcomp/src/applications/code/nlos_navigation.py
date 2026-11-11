"""Navigation around a corner from transient histograms: a car with a lidar (a camera and a laser at the camera) drives
toward a corner; a box waits out of sight around it. A small network, trained on clean renders, estimates where the box
is from every frame's transient histogram, and the car plans its path around it. Path tracing, naive reuse and
ToF ReSTIR render the drive at equal frame time."""
# 1. Build the scene
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import heapq
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import torch
import torch.nn.functional as F
import falcorcomp as falcor

# A road of width 0.4 runs along -z to the corner at the origin and turns to +x. A building, a unit cube over
# x, z in [0.2, 1.2], hides the road after the turn. The box (0.05 x 0.5 x 0.2) is centered at (t, 0, 0), t the clock
# time, set by an animation: x in [t - 0.025, t + 0.025], z in [-0.1, 0.1], and its lower half below the road.
SCENE = """
camera = Camera()
camera.position = float3(0.0, 0.2, 1.0)
camera.target = float3(0.0, 0.2, 0.0)
camera.up = float3(0.0, 1.0, 0.0)
camera.focalLength = 48.0
sceneBuilder.addCamera(camera)
white = StandardMaterial('White')
white.baseColor = float4(1.0, 1.0, 1.0, 1.0)
white.roughness = 1.0
sceneBuilder.addMeshInstance(sceneBuilder.addNode('Floor', Transform(scaling=float3(2.0, 2.0, 2.0))),
                             sceneBuilder.addTriangleMesh(TriangleMesh.createQuad(), white))
sceneBuilder.addMeshInstance(sceneBuilder.addNode('Building', Transform(translation=float3(0.7, 0.5, 0.7))),
                             sceneBuilder.addTriangleMesh(TriangleMesh.createCube(), white))
box = sceneBuilder.addNode('Box', Transform(translation=float3(0.4, 0.0, 0.0)))
sceneBuilder.addMeshInstance(box, sceneBuilder.addTriangleMesh(TriangleMesh.createCube(float3(0.05, 0.5, 0.2)), white))
animation = Animation('BoxPosition', box, 1.0)  # at clock time t, the box is centered at (t, 0, 0)
for t in [0.0, 1.0]:
    key = Transform()
    key.translation = float3(t, 0.0, 0.0)
    animation.addKeyframe(t, key)
sceneBuilder.addAnimation(animation)
"""
Path("nlos_navigation.pyscene").write_text(SCENE)

SIZE = 64
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("nlos_navigation.pyscene")
testbed.resize_frame_buffer(SIZE, SIZE)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

PITCH = np.deg2rad(10.0)                                  # the lidar looks 10 degrees down the road
DIRECTION = np.array([0.0, -np.sin(PITCH), -np.cos(PITCH)])


def place(camera_z, box_x):
    """The car at z = camera_z on the road's center line (lidar height 0.2), the box at x = box_x."""
    position = np.array([0.0, 0.2, camera_z])
    testbed.scene.camera.position = position.tolist()
    testbed.scene.camera.target = (position + DIRECTION).tolist()
    testbed.clock.time = float(box_x)


# 2. Build a render graph for each renderer
HISTOGRAM = {"timeMin": 3.0, "timeMax": 4.28, "timeBin": 64,  # 64 bins of 0.02 in path length
             "maxBounces": 3, "useSingleChannel": True}
# Temporal reuse only. The laser moves with the car: isSceneDynamic keeps the history and re-lights its paths with
# the new laser.
REUSE = {"useTemporalReuse": True, "temporalHistoryLength": 5.0, "isSceneDynamic": True, "spatialReuseIteration": 0,
         "gaugeMode": "avg_grad", "reconnectionRoughnessThreshold": 0.05}
METHODS = {
    "Path tracing": ("TransientHistogramPathTracerInline", {}),
    "Naive reuse": ("TransientHistogramReSTIRInline", {**REUSE, "shiftMappingMethod": "no"}),
    "ToF ReSTIR": ("TransientHistogramReSTIRInline", {**REUSE, "shiftMappingMethod": "area_adaptive"}),
}


def create_graph(tracer, properties):
    graph = testbed.create_render_graph("Navigation")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    # The laser is at the camera, aimed where it looks, with a beam of 5 degrees.
    graph.create_pass("Laser", "LaserLight", {"laserCollocated": True, "laserAngle": 5.0,
                                              "laserPower": [100.0, 100.0, 100.0]})
    graph.create_pass("Tracer", tracer, {**HISTOGRAM, **properties})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    if tracer == "TransientHistogramReSTIRInline":
        graph.add_edge("VBuffer.mvec", "Tracer.mvec")  # reproject the history as the car moves
    graph.add_edge("Laser", "Tracer")
    graph.mark_output("Tracer.histogram")
    testbed.render_graph = graph
    return graph


def render_clean(graph, frames=16):
    """Path tracing with accumulate: the mean of `frames` frames of the graph's samples per pixel."""
    testbed.frame()  # a new graph restarts its sum after its first frame, and a moved camera too: warm up
    graph.get_pass("Tracer").reset()
    for _ in range(frames):
        testbed.frame()
    return graph.get_output("Tracer.histogram").to_numpy() / frames  # (bins, rows, columns)


# 3. Render clean histograms for training: random car and box positions
CLEAN = {"samplesPerPixel": 4096, "accumulate": True}  # x 16 frames: 65536 samples per pixel
TRAINING = Path("training.npz")  # rendered below if missing
if not TRAINING.exists():
    rng = np.random.default_rng(0)
    camera_z, box_x = rng.uniform(0.5, 1.0, 512), rng.uniform(0.3, 0.6, 512)
    graph = create_graph("TransientHistogramPathTracerInline", CLEAN)
    start, histograms = time.perf_counter(), []
    for z, x in zip(camera_z, box_x):
        place(z, x)
        histograms.append(render_clean(graph))
    np.savez(TRAINING, histograms=np.array(histograms), camera_z=camera_z, box_x=box_x)
    print(f"512 training histograms in {time.perf_counter() - start:.0f} s")
training = np.load(TRAINING)


# 4. Train the network: histogram and car position -> box position
class HistogramToPosition(torch.nn.Module):
    def __init__(self, bins):
        super().__init__()
        self.conv1 = torch.nn.Conv2d(bins, 32, 3, padding=1)  # the bins are the input channels
        self.conv2 = torch.nn.Conv2d(32, 64, 3, padding=1)
        self.pool = torch.nn.AdaptiveAvgPool2d((4, 4))
        self.fc1 = torch.nn.Linear(64 * 4 * 4 + 1, 128)
        self.fc2 = torch.nn.Linear(128, 1)

    def forward(self, histogram, camera_z):
        x = self.pool(F.relu(self.conv2(F.relu(self.conv1(histogram))))).flatten(1)
        x = F.relu(self.fc1(torch.cat([x, camera_z[:, None]], 1)))
        return self.fc2(x)[:, 0]


device = "cuda" if torch.cuda.is_available() else "cpu"
torch.manual_seed(0)
histograms = torch.tensor(training["histograms"], dtype=torch.float32, device=device)
camera_z = torch.tensor(training["camera_z"], dtype=torch.float32, device=device)
box_x = torch.tensor(training["box_x"], dtype=torch.float32, device=device)
train, held_out = np.arange(448), np.arange(448, 512)  # the last 64 test the network on positions it has not seen
model = HistogramToPosition(histograms.shape[1]).to(device)
optimizer = torch.optim.Adam(model.parameters(), lr=1e-4)
for epoch in range(500):
    for batch in np.array_split(np.random.default_rng(epoch).permutation(train), len(train) // 32):
        loss = F.l1_loss(model(histograms[batch], camera_z[batch]), box_x[batch])
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
model.eval()


def estimate(histogram, z):
    with torch.no_grad():
        h = torch.tensor(histogram[None], dtype=torch.float32, device=device)
        return float(model(h, torch.tensor([z], dtype=torch.float32, device=device))[0])


errors = [abs(estimate(training["histograms"][i], training["camera_z"][i]) - training["box_x"][i]) for i in held_out]
print(f"Held-out clean histograms: mean error {np.mean(errors):.4f}")

# 5. Drive: 100 frames toward the corner, the box at x = 0.4, with each renderer at equal frame time
BOX_X = 0.4
DRIVE = 1.0 - 0.005 * np.arange(100)  # the car's z in every frame
SPP = {"Path tracing": 768, "Naive reuse": 550, "ToF ReSTIR": 440}  # starting points; ToF ReSTIR keeps 440


def drive(method, spp, record=True):
    """Renders the drive with a new graph; returns the mean frame time in ms and, with record, every frame's histogram.
    Timing runs (record=False) read nothing back."""
    tracer, options = METHODS[method]
    graph = create_graph(tracer, {**options, "samplesPerPixel": spp})
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


target = drive("ToF ReSTIR", SPP["ToF ReSTIR"], record=False)[0]
FRAME_MS = {"ToF ReSTIR": target}
for method in ["Path tracing", "Naive reuse"]:
    trials, spp = {}, SPP[method]
    for attempt in range(4):  # the starting spp, then up to three adjustments
        trials[spp] = drive(method, spp, record=False)[0]
        if abs(trials[spp] / target - 1.0) <= 0.05:
            break
        spp = max(1, round(spp * target / trials[spp]))
        if spp in trials:
            break
    SPP[method] = min(trials, key=lambda count: abs(trials[count] - target))
    FRAME_MS[method] = trials[SPP[method]]
for method in METHODS:
    print(f"{method}: {SPP[method]} spp, {FRAME_MS[method]:.2f} ms per frame")

renders = {method: drive(method, SPP[method])[1] for method in METHODS}
graph = create_graph("TransientHistogramPathTracerInline", CLEAN)
renders["Clean render"] = []
for z in DRIVE:
    place(z, BOX_X)
    renders["Clean render"].append(render_clean(graph))

# 6. Estimate the box's position in every frame
estimates = {name: np.array([estimate(h, z) for h, z in zip(frames, DRIVE)]) for name, frames in renders.items()}
for name, values in estimates.items():
    print(f"{name}: box at x = {np.mean(values[50:]):.3f} (last 50 frames; true {BOX_X}), "
          f"mean error {np.mean(np.abs(values - BOX_X)):.4f}")


# 7. Plan the path around the box: A* on a grid of the road, keeping clear of the walls and the box
CELL = 0.01
xs = np.arange(-0.2, 1.0 + CELL / 2, CELL)  # the road: x in [-0.2, 0.2] for z in [-0.2, 1]
zs = np.arange(-0.2, 1.0 + CELL / 2, CELL)  #           and z in [-0.2, 0.2] for x in [-0.2, 1]
X, Z = np.meshgrid(xs, zs)                   # [z index, x index]
road = (np.abs(X) <= 0.2) | (np.abs(Z) <= 0.2)
# Distance to the road's center line, (0, 1) -> (0, 0) -> (1, 0).
CENTER = np.minimum(np.hypot(X, Z - np.clip(Z, 0, 1)), np.hypot(X - np.clip(X, 0, 1), Z))


def plan(box_center_x, margin=0.03):
    """A* from the car's start (0, 1) to the road's end (1, 0), avoiding the box (inflated by margin) and the walls."""
    free = road & ~((np.abs(X - box_center_x) <= 0.025 + margin) & (np.abs(Z) <= 0.1 + margin))
    free &= (np.abs(X) <= 0.2 - margin) | (np.abs(Z) <= 0.2 - margin)  # keep off the walls
    start, goal = (len(zs) - 1, int(round(0.2 / CELL))), (int(round(0.2 / CELL)), len(xs) - 1)
    cost = 1.0 + 4.0 * np.minimum(CENTER / 0.2, 1.0) ** 2  # prefer the center line
    queue, came, best = [(0.0, start)], {}, {start: 0.0}
    while queue:
        _, cell = heapq.heappop(queue)
        if cell == goal:
            break
        for dz, dx in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]:
            nz, nx = cell[0] + dz, cell[1] + dx
            if 0 <= nz < len(zs) and 0 <= nx < len(xs) and free[nz, nx]:
                g = best[cell] + np.hypot(dz, dx) * cost[nz, nx]
                if g < best.get((nz, nx), np.inf):
                    best[(nz, nx)], came[(nz, nx)] = g, cell
                    heapq.heappush(queue, (g + np.hypot(goal[0] - nz, goal[1] - nx), (nz, nx)))
    path = [goal]
    while path[-1] in came:
        path.append(came[path[-1]])
    path = np.array(path[::-1])
    return np.stack([xs[path[:, 1]], zs[path[:, 0]]], axis=1)


plans = {name: plan(np.mean(values[50:])) for name, values in estimates.items()}
# Does the planned path run into the box where it really is?
hits = {name: bool(np.any((np.abs(path[:, 0] - BOX_X) <= 0.025) & (np.abs(path[:, 1]) <= 0.1)))
        for name, path in plans.items()}
for name, hit in hits.items():
    print(f"{name}: the planned path {'hits' if hit else 'misses'} the box")

# 8. Show the histograms, the estimates and the planned paths
STYLE = {"Clean render": dict(color="0.6"), "Path tracing": dict(color="C0"), "Naive reuse": dict(color="C1"),
         "ToF ReSTIR": dict(color="C2")}
SHOWN_FRAME, SHOWN_BINS = 50, list(range(0, 64, 8))  # 8 of the 64 bins of frame 50
names = ["Clean render", "Path tracing", "Naive reuse", "ToF ReSTIR"]
fig = plt.figure(figsize=(14, 13.5), layout="constrained")
grid = fig.add_gridspec(3, 1, height_ratios=[1.0, 0.75, 0.75])
bins_grid = grid[0].subgridspec(len(names), len(SHOWN_BINS))
for row, name in enumerate(names):
    for column, b in enumerate(SHOWN_BINS):
        axis = fig.add_subplot(bins_grid[row, column])
        top = np.percentile(renders["Clean render"][SHOWN_FRAME][b], 99.5) + 1e-12  # each bin on its own scale
        axis.imshow(np.clip(renders[name][SHOWN_FRAME][b] / top, 0, 1) ** (1 / 2.2), cmap="gray")
        axis.set_xticks([])
        axis.set_yticks([])
        if row == 0:
            length = HISTOGRAM["timeMin"] + (b + 0.5) * (HISTOGRAM["timeMax"] - HISTOGRAM["timeMin"]) / 64
            axis.set_title(f"bin {b} ({length:.2f})", fontsize=9)
        if column == 0:
            label = name if name == "Clean render" else f"{name}\n{SPP[name]} spp\n{FRAME_MS[name]:.1f} ms"
            axis.set_ylabel(label, fontsize=9)
axis = fig.add_subplot(grid[1])
axis.axhline(BOX_X, color="red", linestyle="--", label="the box (true)")
for name in names:
    axis.plot(DRIVE, estimates[name], label=name, **STYLE[name])
axis.set_xlabel("the car's position z (it drives from z = 1 toward the corner)")
axis.set_ylabel("estimated box position x")
axis.invert_xaxis()
axis.legend(ncol=5, fontsize=9)
axis.grid(alpha=0.3)
plan_grid = grid[2].subgridspec(1, len(names))
for column, name in enumerate(names):
    axis = fig.add_subplot(plan_grid[0, column])
    axis.imshow(road, extent=[xs[0], xs[-1], zs[0], zs[-1]], origin="lower", cmap="Greys", alpha=0.25)
    axis.add_patch(plt.Rectangle((BOX_X - 0.025, -0.1), 0.05, 0.2, fill=False, color="red", linewidth=2))
    estimate_x = np.mean(estimates[name][50:])
    axis.add_patch(plt.Rectangle((estimate_x - 0.025, -0.1), 0.05, 0.2, fill=False, linestyle="--", linewidth=1.5,
                                 **STYLE[name]))
    axis.plot(plans[name][:, 0], plans[name][:, 1], linewidth=2, **STYLE[name])
    axis.set_title(f"{name}: box estimated at x = {estimate_x:.3f}\n"
                   f"the path {'hits' if hits[name] else 'misses'} the box", fontsize=9)
    axis.set_xlim(-0.25, 1.0)
    axis.set_ylim(0.6, -0.25)  # the car comes from z = 1, below
    axis.set_aspect("equal")
    axis.set_xticks([])
    axis.set_yticks([])
fig.savefig("nlos_navigation.png", dpi=110)


# A video of the transient histograms at the shown frame, bin by bin, one panel per renderer
def save_video(path, frame, fps=10):
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        print("ffmpeg not found: no video")
        return
    with tempfile.TemporaryDirectory() as folder:
        for b in range(HISTOGRAM["timeBin"]):
            figure, axes = plt.subplots(1, 4, figsize=(10, 2.9))
            scale = np.percentile(renders["Clean render"][frame][b], 99.5) + 1e-12
            for axis, name in zip(axes, names):
                axis.imshow(np.clip(renders[name][frame][b] / scale, 0, 1) ** (1 / 2.2), cmap="gray")
                axis.set_title(name, fontsize=10)
                axis.axis("off")
            length = HISTOGRAM["timeMin"] + (b + 0.5) * (HISTOGRAM["timeMax"] - HISTOGRAM["timeMin"]) / 64
            figure.suptitle(f"path length {length:.2f}", fontsize=10)
            figure.savefig(f"{folder}/bin_{b:03d}.png", dpi=100)
            plt.close(figure)
        subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-framerate", str(fps), "-i", f"{folder}/bin_%03d.png",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", path],
                       check=True)


save_video("nlos_navigation_histograms.mp4", SHOWN_FRAME)
