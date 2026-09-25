"""Offline time-gated rendering of the Cornell box with TimeGatedReSTIRInline."""
# 1. Load the scene
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
graph = testbed.create_render_graph("TimeGatedReSTIR")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserVBufferRT", {
    "samplePattern": "Center", "sampleCount": 1,
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
graph.create_pass("Tracer", "TimeGatedReSTIRInline", {
    # Initial candidates and the gate, as for the path tracer.
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeGateMode": "box", "timeGateWindow": 0.02, "timeCenter": 17.337,
    # Spatial reuse: 3 rounds, each resampling 5 neighbors within 10 pixels.
    "spatialReuseIteration": 3, "spatialReuseNeighborCount": 5,
    "spatialReuseGatherRadius": 10.0, "useTemporalReuse": False,
    # Path-length-aware shift mapping between pixels.
    "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
    "specularRoughnessThreshold": 0.05,
})
graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
graph.create_pass("ToneMapper", "ToneMapper", {"autoExposure": False})

graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
graph.add_edge("Laser.viewW", "Tracer.laserviewW")
graph.add_edge("Tracer.color", "Accumulate.input")
graph.add_edge("Accumulate.output", "ToneMapper.src")
graph.mark_output("Accumulate.output")  # output 0: linear radiance
graph.mark_output("ToneMapper.dst")     # output 1: tone mapped
testbed.render_graph = graph

# 3. Render
for _ in range(64):  # 64 frames x 16 initial candidates
    testbed.frame()

# 4. Save the image
testbed.capture_output("time_gated_restir.exr", 0)
testbed.capture_output("time_gated_restir.png", 1)
