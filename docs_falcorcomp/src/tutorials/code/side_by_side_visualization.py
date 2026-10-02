"""Compare two images in a window: two time gates of the Cornell box, shown with
SplitScreenPass (a draggable divider) or SideBySidePass (two halves next to each other)."""
# 1. Open a window and load the scene
import falcorcomp as falcor

VIEW = "split"  # "split": SplitScreenPass; "side_by_side": SideBySidePass

SIZE = 1024
testbed = falcor.Testbed(create_window=True, width=SIZE, height=SIZE,
                         title="Side-by-side visualization")
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The same path tracer twice, with two gates: early light on the left, later light
# on the right.
GATES = {"Early": 16.9, "Late": 17.337}

# 2. Build the two images to compare
graph = testbed.create_render_graph("SideBySide")
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

# 3. Put them side by side
labels = {"leftLabel": f"Gate {GATES['Early']}", "rightLabel": f"Gate {GATES['Late']}",
          "showTextLabels": True}
if VIEW == "split":
    # Left input left of a divider, right input right of it, over the same pixels.
    graph.create_pass("Compare", "SplitScreenPass", {**labels, "splitLocation": 0.5})
else:
    # A half-width window of each input, next to each other: columns
    # imageLeftBound to imageLeftBound + SIZE / 2 of both images (here the middle).
    graph.create_pass("Compare", "SideBySidePass", {**labels, "imageLeftBound": SIZE // 4})
graph.add_edge("ToneMapEarly.dst", "Compare.leftInput")
graph.add_edge("ToneMapLate.dst", "Compare.rightInput")
graph.mark_output("Compare.output")
testbed.render_graph = graph

# 4. Run
testbed.run()
