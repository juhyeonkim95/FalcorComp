"""Event camera simulation of the Cornell box with a moving camera: path tracing, correlated path tracing and
EventSVGF at 2 samples per pixel per frame, against a reference."""
# 1. Load the scene
import falcorcomp as falcor
import numpy as np
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4.pbrt")  # with its area light
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The camera moves forward at 1000 frames per second.
camera = testbed.scene.camera
START = np.array([camera.position.x, camera.position.y, camera.position.z])
FORWARD = np.array([camera.target.x, camera.target.y, camera.target.z]) - START
FPS, FRAMES = 1000, 30
THRESHOLD = 0.2  # event threshold C on the brightness change


def move_camera(frame):
    position = START + 2.0 * FORWARD * frame / FPS
    camera.position = falcor.float3(*position)
    camera.target = falcor.float3(*(position + FORWARD))


# 2. Build the render graphs
def build_graph(method, spp, subframes=1):
    graph = testbed.create_render_graph(method)
    # Primary hits at the pixel centers, shared by the path tracers.
    graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    tracers = ["TracerA"] if method == "path" else ["TracerA", "TracerB"]
    for tracer in tracers:
        graph.create_pass(tracer, "PathTracer", {"samplesPerPixel": spp, "fixedSeed": 0})
        graph.add_edge("GBuffer.vbuffer", f"{tracer}.vbuffer")

    if method == "eventsvgf":
        graph.create_pass("Difference", "EventSVGF", {})
        inputs = {"TracerA.color": "color1", "TracerB.color": "color2", "TracerA.albedo": "albedo",
                  "GBuffer.emissive": "emission", "GBuffer.linearZ": "linearZ", "GBuffer.guideNormalW": "normal",
                  "GBuffer.mvec": "mvec"}
    else:
        sampling = "independent" if method == "path" else "correlated"
        graph.create_pass("Difference", "EventDifference", {"sampling": sampling, "subframes": subframes})
        inputs = {"TracerA.color": "color1"} if method == "path" else {"TracerA.color": "color1", "TracerB.color": "color2"}
    for source, target in inputs.items():
        graph.add_edge(source, f"Difference.{target}")

    graph.create_pass("Events", "EventGenerator", {"mode": "probabilistic", "threshold": THRESHOLD})
    graph.add_edge("Difference.deltaL", "Events.deltaL")
    for output in ["Difference.primal", "Difference.deltaI", "Difference.deltaL", "Events.events"]:
        graph.mark_output(output)
    return graph


# 3. Render the camera path
def set_seeds(graph, correlated, frame, subframe=0, subframes=1):
    seed = lambda f: (f + 1) * subframes + subframe  # seeds are non-negative
    if correlated:
        # TracerA reuses the previous frame's seed, TracerB takes the current one.
        graph.get_pass("TracerA").fixedSeed = seed(frame - 1)
        graph.get_pass("TracerB").fixedSeed = seed(frame)
    else:
        graph.get_pass("TracerA").fixedSeed = seed(frame)


def read(graph):
    luminance = np.array([0.2126, 0.7152, 0.0722])
    return {
        "primal": graph.get_output("Difference.primal").to_numpy()[..., :3],
        "deltaI": graph.get_output("Difference.deltaI").to_numpy()[..., :3] @ luminance,
        "deltaL": graph.get_output("Difference.deltaL").to_numpy(),
        "events": graph.get_output("Events.events").to_numpy(),
    }


def render(method):
    graph = build_graph(method, spp=2 if method == "path" else 1)
    testbed.render_graph = graph
    for frame in range(FRAMES):
        move_camera(frame)
        set_seeds(graph, method != "path", frame)
        testbed.frame()
    return read(graph)


results = {
    "Path tracer": render("path"),                 # 2 spp, new random numbers every frame
    "Correlated path tracer": render("correlated"),  # 1 + 1 spp, the previous frame's seed reused
    "EventSVGF": render("eventsvgf"),             # 1 + 1 spp, denoised difference
}


# 4. Reference: the correlated difference of the last two frames, 4096 + 4096 spp
SUBFRAMES = 256
graph = build_graph("correlated", spp=16, subframes=SUBFRAMES)
testbed.render_graph = graph
for frame in [FRAMES - 2, FRAMES - 1]:
    move_camera(frame)
    for subframe in range(SUBFRAMES):
        set_seeds(graph, True, frame, subframe, SUBFRAMES)
        testbed.frame()
results["Reference"] = read(graph)


# 5. Show primal, intensity change, brightness change and events
reference = results["Reference"]
range_I = np.percentile(np.abs(reference["deltaI"]), 99.5)
range_L = np.percentile(np.abs(reference["deltaL"]), 99.5)
figure, axes = plt.subplots(len(results), 4, figsize=(13, 3.3 * len(results)))
for row, (name, result) in enumerate(results.items()):
    panels = [
        (np.clip(result["primal"], 0, 1) ** (1 / 2.2), None, None, "primal"),
        (result["deltaI"], "RdBu_r", range_I, "ΔI"),
        (result["deltaL"], "RdBu_r", range_L, "ΔL"),
        (np.clip(result["events"], -1, 1), "bwr", 1, "events (red +, blue −)"),
    ]
    for column, (image, cmap, limit, title) in enumerate(panels):
        axis = axes[row, column]
        axis.imshow(image, cmap=cmap, vmin=-limit if limit else None, vmax=limit)
        axis.set_xticks([])
        axis.set_yticks([])
        if row == 0:
            axis.set_title(title)
    if name != "Reference":
        # Events per pixel where the reference has none.
        false_events = np.mean(np.abs(result["events"]) * (reference["events"] == 0))
        axes[row, 3].text(0.02, 0.97, f"false events {false_events:.4f}", transform=axes[row, 3].transAxes,
                          va="top", fontsize=9, bbox=dict(facecolor="white", alpha=0.8, edgecolor="none"))
    axes[row, 0].set_ylabel(name)
figure.tight_layout()
figure.savefig("event_camera.png", dpi=80)
