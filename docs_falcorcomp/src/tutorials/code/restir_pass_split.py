"""GPU time of TimeGatedReSTIRInline's spatial reuse in one pass and in two passes
(spatialReuseTwoPass), for each path-length-aware shift mapping."""
# 1. Load the scene
import numpy as np
import falcorcomp as falcor

falcor.Logger.verbosity = falcor.Logger.Level.Error
testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

ITERATIONS = 3  # spatial reuse rounds per frame
RESTIR = {"samplesPerPixel": 16, "maxBounces": 6,
          "timeGateMode": "box", "timeGateWindow": 0.02, "timeCenter": 17.337,
          "spatialReuseIteration": ITERATIONS, "spatialReuseNeighborCount": 5,
          "spatialReuseGatherRadius": 10.0, "useTemporalReuse": False,
          "gaugeMode": "avg_grad", "reconnectionRoughnessThreshold": 0.05}


# 2. Profile one configuration
def profile(properties):
    """Mean GPU time (ms) per frame of the whole pass and of its kernels, and the image."""
    graph = testbed.create_render_graph("TimeGatedReSTIR")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserLight", {
        "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
        "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
    })
    graph.create_pass("Tracer", "TimeGatedReSTIRInline", {**RESTIR, **properties})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser", "Tracer")
    graph.mark_output("Tracer.color")
    testbed.render_graph = graph
    for _ in range(50):  # compile the shaders and warm up the GPU
        testbed.frame()
    testbed.profiler.enabled = True
    testbed.profiler.start_capture()
    for _ in range(200):
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
    image = graph.get_output("Tracer.color").to_numpy()[..., :3].copy()
    return times, image


# 3. One pass and two passes for each shift mapping
# The initial sample generation is the same in both: a run without spatial reuse
# measures it, and the rest of each frame is the spatial reuse.
print(f"GPU ms per frame of the spatial reuse, {ITERATIONS} rounds (512 x 512, 16 spp)")
for method in ["local_tangent", "barycentric", "ray_trace"]:
    initial, _ = profile({"shiftmapMethod": method, "spatialReuseIteration": 0})
    single, image_single = profile({"shiftmapMethod": method, "spatialReuseTwoPass": False})
    split, image_split = profile({"shiftmapMethod": method, "spatialReuseTwoPass": True})
    one_pass = single["total"] - initial["total"]
    two_passes = split["total"] - initial["total"]
    difference = np.abs(image_split - image_single).sum() / np.abs(image_single).sum()
    print(f"{method:14s} one pass {one_pass:6.3f}   two passes {two_passes:6.3f} "
          f"(pairs {split['pairs']:.3f} + resample {split['resample']:.3f})   "
          f"{one_pass / two_passes:.2f}x faster   image difference {difference:.1e}")
