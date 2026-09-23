"""Offline time-gated rendering of the Cornell box with TimeGatedPathTracerInline."""
# 1. Load the scene
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
graph = testbed.create_render_graph("TimeGated")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserVBufferRT", {
    "samplePattern": "Center", "sampleCount": 1,
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
graph.create_pass("Tracer", "TimeGatedPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False,
    "timeGateMode": "box", "timeGateWindow": 0.1, "timeMin": 17.337, "timeMax": 17.337,
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
for _ in range(64):  # 64 frames x 16 spp = 1024 spp
    testbed.frame()

# 4. Save the image
testbed.capture_output("time_gated.exr", 0)
testbed.capture_output("time_gated.png", 1)
