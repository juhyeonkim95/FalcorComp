"""Online TGPT and TG ReSTIR side by side in a window (SplitScreenPass) while the gate sweeps."""
# 1. Open a window and load the scene
import falcorcomp as falcor

SIZE = 1024
testbed = falcor.Testbed(create_window=True, width=SIZE, height=SIZE,
                         title="TGPT | TG ReSTIR")
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The gate moves to the next center every frame (shiftGate): 100 centers from 16.75
# to 17.331, then it starts again. Both tracers start at the first center and move
# together.
STEP = (17.331213307240706 - 16.75) / 99
GATE = {"timeGateMode": "box", "timeGateWindow": 0.01, "shiftGate": True,
        "timeMin": 16.75, "timeMax": 16.75 + 100 * STEP, "timeBin": 100}
# 37 spp for the path tracer costs about as much as ReSTIR's 32 (RTX 3090, see the
# online tutorial).
PT = {"samplesPerPixel": 37, "maxBounces": 6, **GATE}
RESTIR = {"samplesPerPixel": 32, "maxBounces": 6, **GATE,
          "spatialReuseIteration": 1, "spatialReuseNeighborCount": 3,
          "useTemporalReuse": True, "temporalHistoryLength": 10.0,
          "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
          "specularRoughnessThreshold": 0.05}

# 2. Build the render graph: both tracers share the V-buffer and the laser
graph = testbed.create_render_graph("SplitScreen")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
graph.create_pass("PT", "TimeGatedPathTracerInline", PT)
graph.create_pass("ReSTIR", "TimeGatedReSTIRInline", RESTIR)
for tracer in ["PT", "ReSTIR"]:
    graph.add_edge("VBuffer.vbuffer", f"{tracer}.vbuffer")
    graph.add_edge("VBuffer.viewW", f"{tracer}.viewW")
    graph.add_edge("Laser", tracer)
    # Tone map each side the same way before they are put side by side.
    graph.create_pass(f"ToneMap{tracer}", "ToneMapper", {"autoExposure": False})
    graph.add_edge(f"{tracer}.color", f"ToneMap{tracer}.src")

# Motion vectors let ReSTIR's temporal reuse follow the camera when it moves.
graph.add_edge("VBuffer.mvec", "ReSTIR.mvec")

# SplitScreenPass shows its left input left of a divider, its right input right of it.
graph.create_pass("Split", "SplitScreenPass", {
    "leftLabel": "TGPT", "rightLabel": "TG ReSTIR",
    "showTextLabels": True, "splitLocation": 0.5,
})
graph.add_edge("ToneMapPT.dst", "Split.leftInput")
graph.add_edge("ToneMapReSTIR.dst", "Split.rightInput")
graph.mark_output("Split.output")
testbed.render_graph = graph

# 3. Run
testbed.run()
