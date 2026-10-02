"""Draw the laser beam over a time-gated image of the Cornell box with LaserPositionViewer."""
# 1. Load the scene and move the camera
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The scene's camera looks down the laser beam; look from above and to the right
# instead, so that the beam crosses the image.
camera = testbed.scene.camera
camera.position = falcor.float3(1.6, 2.2, 8.5)
camera.target = falcor.float3(0.0, 1.0, 0.0)
camera.up = falcor.float3(0.0, 1.0, 0.0)
camera.focalLength = 60.0  # mm

# 2. Build the render graph
graph = testbed.create_render_graph("LaserVisualization")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
graph.create_pass("Tracer", "TimeGatedPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False,
    "timeGateMode": "box", "timeGateWindow": 0.1, "timeMin": 18.5, "timeMax": 18.5,
})
graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
# LaserPositionViewer draws the laser's beam over its input, like light in fog.
graph.create_pass("Viewer", "LaserPositionViewer", {
    "showCone": True, "coneColor": [1.0, 0.0, 0.0],
    "beamRadius": 0.02, "coneDensity": 20.0,
})
graph.create_pass("ToneMapper", "ToneMapper", {"autoExposure": False})

graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser", "Tracer")
graph.add_edge("Tracer.color", "Accumulate.input")
# The viewer needs the laser (execution edge) and the V-buffer, to stop the beam
# where the scene hides it.
graph.add_edge("Laser", "Viewer")
graph.add_edge("VBuffer.vbuffer", "Viewer.vbuffer")
graph.add_edge("VBuffer.viewW", "Viewer.viewW")
graph.add_edge("Accumulate.output", "Viewer.input")
graph.add_edge("Viewer.output", "ToneMapper.src")
graph.mark_output("Accumulate.output")  # output 0: the time-gated image alone
graph.mark_output("ToneMapper.dst")     # output 1: with the laser, tone mapped
testbed.render_graph = graph

# 3. Render
for _ in range(256):  # 256 frames x 16 spp = 4096 spp
    testbed.frame()

# 4. Save the images
testbed.capture_output("time_gated.exr", 0)
testbed.capture_output("laser_visualization.png", 1)
