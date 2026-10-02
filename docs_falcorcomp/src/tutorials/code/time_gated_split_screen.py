"""Two time gates of the Cornell box side by side in a window (SplitScreenPass)."""
# 1. Open a window and load the scene
import falcorcomp as falcor

SIZE = 1024
testbed = falcor.Testbed(create_window=True, width=SIZE, height=SIZE,
                         title="Two time gates")
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The same path tracer twice, with two gates: early light on the left, later light
# on the right.
GATES = {"Early": 16.9, "Late": 17.337}

# 2. Build the render graph: both tracers share the V-buffer and the laser
graph = testbed.create_render_graph("SplitScreen")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
for name, center in GATES.items():
    graph.create_pass(name, "TimeGatedPathTracerInline", {
        "samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False,
        "timeGateMode": "box", "timeGateWindow": 0.1, "timeMin": center, "timeMax": center,
    })
    graph.add_edge("VBuffer.vbuffer", f"{name}.vbuffer")
    graph.add_edge("VBuffer.viewW", f"{name}.viewW")
    graph.add_edge("Laser", name)
    # Average the frames, then tone map each side the same way.
    graph.create_pass(f"Accumulate{name}", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.create_pass(f"ToneMap{name}", "ToneMapper", {"autoExposure": False})
    graph.add_edge(f"{name}.color", f"Accumulate{name}.input")
    graph.add_edge(f"Accumulate{name}.output", f"ToneMap{name}.src")

# SplitScreenPass shows its left input left of a divider, its right input right of it.
graph.create_pass("Split", "SplitScreenPass", {
    "leftLabel": f"Gate {GATES['Early']}", "rightLabel": f"Gate {GATES['Late']}",
    "showTextLabels": True, "splitLocation": 0.5,
})
graph.add_edge("ToneMapEarly.dst", "Split.leftInput")
graph.add_edge("ToneMapLate.dst", "Split.rightInput")
graph.mark_output("Split.output")
testbed.render_graph = graph

# 3. Run
testbed.run()
