"""Offline CW-ToF rendering of the Cornell box with CWToFPathTracerInline."""
# 1. Load the scene
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
graph = testbed.create_render_graph("CWToF")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
# A point light at the camera, as in a CW-ToF camera.
graph.create_pass("Light", "LaserLight", {
    "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
})
graph.create_pass("Tracer", "CWToFPathTracerInline", {
    "samplesPerPixel": 8, "maxBounces": 3,
    "computeDirect": False,  # indirect light only: the multipath part of the measurement
    "waveform": "cos", "modulationWavelength": 0.01, "phase": 0.0,
    "useAntitheticSampling": True,
    "useSingleChannel": True, "singleChannel": "luminance",
})
graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})

graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.add_edge("Tracer.color", "Accumulate.input")
graph.mark_output("Accumulate.output")
testbed.render_graph = graph

# 3. Render
for _ in range(1024):  # 1024 frames x 8 spp = 8192 spp
    testbed.frame()

# 4. Save the image
image = graph.get_output("Accumulate.output").to_numpy()[..., 0]  # one channel (luminance)
np.save("cwtof.npy", image)
# The measurement is signed: show it with a diverging colormap, 0 in white.
limit = np.percentile(np.abs(image), 95)
plt.imsave("cwtof.png", image, cmap="bwr", vmin=-limit, vmax=limit)
