"""Online (interactive) transient histogram rendering of the Cornell box."""

# 1. Open a window and load the scene
import falcorcomp as falcor

SIZE = 512  # render size; the window is twice as wide
testbed = falcor.Testbed(create_window=True, width=2 * SIZE, height=SIZE, title="Transient histogram")
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
fixed_size = {"outputSize": "Fixed", "fixedOutputSize": [SIZE, SIZE]}

graph = testbed.create_render_graph("Transient")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, **fixed_size})
graph.create_pass("Laser", "LaserVBufferRT", {
    "samplePattern": "Center", "sampleCount": 1,
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
graph.create_pass("Tracer", "TransientHistogramPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False,
    "timeMin": 16.75, "timeMax": 18.03, "timeBin": 64, "accumulate": True, **fixed_size,
})
graph.create_pass("Viewer", "TransientHistogramViewer", {})
graph.create_pass("ToneMapper", "ToneMapper", {"autoExposure": False})

graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
graph.add_edge("Laser.viewW", "Tracer.laserviewW")
graph.add_edge("Tracer.histogram", "Viewer.histogram")
graph.add_edge("Viewer.output", "ToneMapper.src")
graph.mark_output("ToneMapper.dst")  # shown in the window
testbed.render_graph = graph

# 3. Run
testbed.run()
