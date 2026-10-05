"""GPU time of InlinePathTracer (inline ray tracing) and Falcor's PathTracer on the same
scene, light and paths. Usage:

    python inline_ray_tracing.py [scene.pbrt] [width] [height]

(default: the Cornell box at 1024 x 1024)."""
# 1. A scene with a point light at the camera
import os
import subprocess
import sys

import numpy as np
import falcorcomp as falcor

SCENE = sys.argv[1] if len(sys.argv) > 1 else "cornell-box/scene-v4-nolight.pbrt"
WIDTH = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
HEIGHT = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
TRACERS = ["InlinePathTracer", "PathTracer"]

# Falcor's PathTracer only sees the scene's own lights, so the point light is added
# to the scene in a small .pyscene next to it. InlinePathTracer gets the same light
# from LaserLight. Each pass is aimed along the camera view in time_tracer().
PYSCENE = os.path.splitext(SCENE)[0] + "-camera-light.pyscene"
with open(PYSCENE, "w") as file:
    file.write(f"""import math
sceneBuilder.importScene("{os.path.basename(SCENE)}")
light = PointLight("CameraLight")
light.openingAngle = math.pi / 2
light.intensity = float3(10.0, 10.0, 10.0)
sceneBuilder.addLight(light)
""")


# 2. Time one tracer
def time_tracer(tracer):
    """Median GPU time (ms) of the tracer over 200 frames of 16 samples per pixel."""
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(PYSCENE)
    testbed.resize_frame_buffer(WIDTH, HEIGHT)
    camera = testbed.scene.camera
    camera.aspectRatio = WIDTH / HEIGHT
    camera.apertureRadius = 0.0  # no depth of field: same primary rays for both
    testbed.clock.pause()

    # Only the point light at the camera, aimed along the view.
    position = np.array([camera.position.x, camera.position.y, camera.position.z])
    target = np.array([camera.target.x, camera.target.y, camera.target.z])
    light = testbed.scene.getLight("CameraLight")
    light.position = camera.position
    light.direction = falcor.float3(*((target - position) / np.linalg.norm(target - position)).tolist())
    settings = testbed.scene.renderSettings
    settings.useEnvLight = False
    settings.useEmissiveLights = False
    testbed.scene.renderSettings = settings

    graph = testbed.create_render_graph("PathTracer")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1,
                                               "useAlphaTest": True})
    if tracer == "PathTracer":
        # Five bounces after the primary hit, no Russian roulette: the same paths.
        graph.create_pass("Tracer", "PathTracer", {"samplesPerPixel": 16, "maxSurfaceBounces": 5,
                                                   "useRussianRoulette": False})
    else:
        graph.create_pass("Light", "LaserLight", {"isLightSourceLaser": False, "laserCollocated": True,
                                                  "laserPower": [10.0, 10.0, 10.0]})
        graph.create_pass("Tracer", tracer, {"samplesPerPixel": 16, "maxBounces": 6, "computeDirect": True,
                                             "useAlphaTest": True})
        graph.add_edge("Light", "Tracer")
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.mark_output("Tracer.color")
    testbed.render_graph = graph

    for _ in range(30):  # compile the shaders and warm up the GPU
        testbed.frame()
    testbed.profiler.enabled = True
    testbed.profiler.start_capture()
    for _ in range(200):
        testbed.frame()
    events = testbed.profiler.end_capture()["events"]
    records = next(event["records"] for name, event in events.items() if name.endswith("/Tracer/gpu_time"))
    return sorted(records)[len(records) // 2]


# 3. Each tracer in its own process, best of three
if len(sys.argv) > 4:  # a child process: time one tracer and print it
    print("RESULT", time_tracer(sys.argv[4]), flush=True)
    sys.exit()

times = {}
for tracer in TRACERS:
    runs = []
    for _ in range(3):
        output = subprocess.run([sys.executable, __file__, SCENE, str(WIDTH), str(HEIGHT), tracer],
                                capture_output=True, text=True).stdout
        runs.append(float(next(line for line in output.splitlines() if line.startswith("RESULT")).split()[1]))
    times[tracer] = min(runs)
for tracer, ms in times.items():
    print(f"{tracer:18s} {ms:7.2f} ms  ({ms / times['InlinePathTracer']:.2f}x)")
