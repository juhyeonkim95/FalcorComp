"""GPU time of the path-length-aware ReSTIR passes with their reuse in one kernel and in two
(spatialReuseTwoPass, temporalReuseTwoPass): TimeGatedReSTIRInline and
TransientHistogramReSTIRInline on the Cornell box."""
# 1. Load the scene
import os

import numpy as np
import falcorcomp as falcor

falcor.Logger.verbosity = falcor.Logger.Level.Error
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

REUSE = {"spatialReuseNeighborCount": 5, "spatialReuseGatherRadius": 10.0,
         "gaugeMode": "avg_grad", "reconnectionRoughnessThreshold": 0.05}
# The time-gated ReSTIR tutorial's settings: a narrow gate, 3 spatial rounds.
TIME_GATED = {"samplesPerPixel": 16, "maxBounces": 6,
              "timeGateMode": "box", "timeGateWindow": 0.02, "timeCenter": 17.337,
              "spatialReuseIteration": 3, "useTemporalReuse": False, **REUSE}
# The transient ReSTIR tutorial's settings: 64 bins, reuse in every bin.
TRANSIENT = {"samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False,
             "timeMin": 16.75, "timeMax": 18.03, "timeBin": 64,
             "spatialReuseIteration": 1, "useTemporalReuse": False, **REUSE}


# 2. Profile one configuration
def profile(tracer, properties, output, size, frames, laser=None, move=None):
    """Mean GPU time (ms) per frame of the pass and of its kernels, and the output.
    move(frame), if given, moves the camera before each frame."""
    width, height = size if isinstance(size, tuple) else (size, size)
    testbed.resize_frame_buffer(width, height)
    graph = testbed.create_render_graph("ReSTIR")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserLight", laser or {
        "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
        "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
    })
    graph.create_pass("Tracer", tracer, properties)
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("VBuffer.mvec", "Tracer.mvec")  # for temporal reuse
    graph.add_edge("Laser", "Tracer")
    graph.mark_output(f"Tracer.{output}")
    testbed.render_graph = graph
    move = move or (lambda frame: None)
    for frame in range(20):  # compile the shaders and warm up the GPU
        move(frame)
        testbed.frame()
    testbed.profiler.enabled = True
    testbed.profiler.start_capture()
    for frame in range(20, 20 + frames):
        move(frame)
        testbed.frame()
    events = testbed.profiler.end_capture()["events"]
    testbed.profiler.enabled = False
    # Event names are paths of nested profiler scopes, e.g. ".../Tracer/pairs/gpu_time".
    times = {}
    for name, event in events.items():
        if name.endswith("/Tracer/gpu_time"):
            times["total"] = event["stats"]["mean"]
        elif "/Tracer/" in name and name.endswith("/gpu_time"):
            times[name.split("/Tracer/")[1][:-len("/gpu_time")]] = event["stats"]["mean"]
    result = graph.get_output(f"Tracer.{output}").to_numpy()[..., :3].copy()
    return times, result


def compare(label, tracer, settings, two_pass_option, kernels, output, size, frames, **scene):
    """Times the reuse in one kernel and in two. The initial sample generation is the
    same in both: a run without reuse measures it, and the rest of the frame is the reuse."""
    initial, _ = profile(tracer, {**settings, "spatialReuseIteration": 0, "useTemporalReuse": False},
                         output, size, frames, **scene)
    one, result_one = profile(tracer, {**settings, two_pass_option: False}, output, size, frames, **scene)
    two, result_two = profile(tracer, {**settings, two_pass_option: True}, output, size, frames, **scene)
    one_kernel = one["total"] - initial["total"]
    two_kernels = two["total"] - initial["total"]
    parts = " + ".join(f"{kernel} {two.get(kernel, 0.0):.2f}" for kernel in kernels)
    difference = np.abs(result_two - result_one).sum() / np.abs(result_one).sum()
    print(f"{label:40s} one kernel {one_kernel:7.2f}   two kernels {two_kernels:7.2f} ({parts})   "
          f"{one_kernel / two_kernels:.2f}x faster   difference {difference:.1e}", flush=True)


# 3. Time-gated ReSTIR: spatial reuse, 3 rounds, 512 x 512
print("GPU ms per frame of the reuse")
for method in ["local_tangent", "barycentric", "ray_trace"]:
    compare(f"TG spatial, {method}", "TimeGatedReSTIRInline", {**TIME_GATED, "shiftMappingMethod": method},
            "spatialReuseTwoPass", ["pairs", "resample"], "color", 512, 200)

# 4. Transient histogram ReSTIR: spatial reuse, 1 round, 64 bins, 256 x 256
for method in ["local_tangent", "barycentric", "ray_trace"]:
    compare(f"TH spatial, {method}", "TransientHistogramReSTIRInline", {**TRANSIENT, "shiftMappingMethod": method},
            "spatialReuseTwoPass", ["pairs", "resample"], "histogram", 256, 30)

# 5. Transient histogram ReSTIR: temporal reuse (static camera), 64 bins, 256 x 256
for method in ["local_tangent", "barycentric", "ray_trace"]:
    compare(f"TH temporal, {method}", "TransientHistogramReSTIRInline",
            {**TRANSIENT, "shiftMappingMethod": method, "spatialReuseIteration": 0, "useTemporalReuse": True},
            "temporalReuseTwoPass", ["temporalPairs", "temporalResample"], "histogram", 256, 30)

# 6. Transient histogram ReSTIR: temporal reuse in Veach, Ajar (if downloaded), with the
# transient ReSTIR online tutorial's laser and a camera moving forward, 480 x 270
VEACH_AJAR = "veach-ajar/scene-v4.pbrt"
if os.path.exists(VEACH_AJAR):
    testbed.render_graph = None  # release the Cornell box's graph before loading
    testbed.load_scene(VEACH_AJAR)
    camera = testbed.scene.camera
    camera.aspectRatio = 480 / 270
    camera.apertureRadius = 0.0
    start = np.array([camera.position.x, camera.position.y, camera.position.z])
    target = np.array([camera.target.x, camera.target.y, camera.target.z])
    forward = (target - start) / np.linalg.norm(target - start)

    def move(frame):
        offset = forward * 0.005 * (frame % 60)  # forward 0.005 per frame, back every 60 frames
        camera.position = falcor.float3(*(start + offset).tolist())
        camera.target = falcor.float3(*(target + offset).tolist())

    laser = {"laserPosition": [4.054023, 1.616475, -2.306524],
             "laserDirection": [-0.990015, -0.032298, -0.137213],
             "laserPower": [1000.0, 1000.0, 1000.0], "laserAngle": 0.0}
    settings = {**TRANSIENT, "samplesPerPixel": 32, "useAlphaTest": True, "timeMin": 19.0, "timeMax": 21.0,
                "spatialReuseIteration": 0, "useTemporalReuse": True, "temporalHistoryLength": 20.0}
    for method in ["local_tangent", "barycentric", "ray_trace"]:
        compare(f"TH temporal (Veach, Ajar), {method}", "TransientHistogramReSTIRInline",
                {**settings, "shiftMappingMethod": method}, "temporalReuseTwoPass",
                ["temporalPairs", "temporalResample"], "histogram", (480, 270), 30, laser=laser, move=move)
