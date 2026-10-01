"""Event camera simulation of the Cornell box with a moving camera: the brightness change between two frames from
path tracing with independent and with correlated random numbers, at 1024 samples per pixel per frame."""
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
FPS = 1000
THRESHOLD = 0.2  # event threshold C on the brightness change


def move_camera(frame):
    position = START + 2.0 * FORWARD * frame / FPS
    camera.position = falcor.float3(*position)
    camera.target = falcor.float3(*(position + FORWARD))


# 2. Build the render graph
def build_graph(correlated, subframes):
    graph = testbed.create_render_graph("correlated" if correlated else "independent")
    # Primary hits at the pixel centers, shared by the path tracers.
    graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    tracers = ["TracerA", "TracerB"] if correlated else ["TracerA"]
    for tracer in tracers:
        graph.create_pass(tracer, "PathTracer", {"samplesPerPixel": 16, "fixedSeed": 0})
        graph.add_edge("GBuffer.vbuffer", f"{tracer}.vbuffer")
    # The difference of each frame with the previous one, averaged over `subframes` executions per frame.
    graph.create_pass("Difference", "EventDifference",
                      {"sampling": "correlated" if correlated else "independent", "subframes": subframes})
    for index, tracer in enumerate(tracers):
        graph.add_edge(f"{tracer}.color", f"Difference.color{index + 1}")
    graph.create_pass("Events", "EventGenerator", {"mode": "probabilistic", "threshold": THRESHOLD})
    graph.add_edge("Difference.deltaL", "Events.deltaL")
    for output in ["Difference.primal", "Difference.deltaI", "Difference.deltaL", "Events.events"]:
        graph.mark_output(output)
    return graph


# 3. Render two frames
def render(correlated, samples):
    tracers = 2 if correlated else 1
    subframes = samples // (16 * tracers)  # 16 samples per PathTracer execution
    graph = build_graph(correlated, subframes)
    testbed.render_graph = graph
    for frame in [0, 1]:  # the difference only needs the previous frame
        move_camera(frame)
        for subframe in range(subframes):
            # Seed of frame f in execution k; seeds are non-negative and never repeat.
            seed = lambda f: (f + 1) * subframes + subframe
            if correlated:
                # TracerA reuses the previous frame's seed, TracerB takes the current one.
                graph.get_pass("TracerA").fixedSeed = seed(frame - 1)
                graph.get_pass("TracerB").fixedSeed = seed(frame)
            else:
                graph.get_pass("TracerA").fixedSeed = seed(frame)
            testbed.frame()
    luminance = np.array([0.2126, 0.7152, 0.0722])
    return {
        "primal": graph.get_output("Difference.primal").to_numpy()[..., :3],
        "deltaI": graph.get_output("Difference.deltaI").to_numpy()[..., :3] @ luminance,
        "deltaL": graph.get_output("Difference.deltaL").to_numpy(),
        "events": graph.get_output("Events.events").to_numpy(),
    }


SAMPLES = 1024  # per pixel per frame
results = {
    "Path tracer\n(independent, 1024 spp)": render(False, SAMPLES),
    "Correlated path tracer\n(512 + 512 spp)": render(True, SAMPLES),
}


# 4. Show primal, intensity change, brightness change and events
correlated = list(results.values())[1]
range_I = np.percentile(np.abs(correlated["deltaI"]), 99.5)
range_L = np.percentile(np.abs(correlated["deltaL"]), 99.5)
figure, axes = plt.subplots(len(results), 4, figsize=(13, 3.4 * len(results)))
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
    axes[row, 3].text(0.02, 0.97, f"{np.mean(np.abs(result['events'])):.4f} events / pixel",
                      transform=axes[row, 3].transAxes, va="top", fontsize=9,
                      bbox=dict(facecolor="white", alpha=0.8, edgecolor="none"))
    axes[row, 0].set_ylabel(name)
figure.tight_layout()
figure.savefig("event_camera.png", dpi=80)
