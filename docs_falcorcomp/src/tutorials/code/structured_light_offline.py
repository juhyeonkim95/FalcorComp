"""Offline structured-light rendering of the Cornell box with StructuredLightPathTracerInline."""
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
graph = testbed.create_render_graph("StructuredLight")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Tracer", "StructuredLightPathTracerInline", {
    "samplesPerPixel": 8, "maxBounces": 3,
    "computeDirect": False,  # indirect light only
    # A projector 0.4 to the right of the camera, with a wider field of view (the camera's is 19.5).
    "projectorPosition": [0.4, 1.0, 6.8], "projectorDirection": [0.0, 0.0, -1.0],
    "projectorFov": [30.0, 30.0], "projectorIntensity": [10.0, 10.0, 10.0],
    # Vertical cos stripes, 100 periods across the projector's field of view.
    "pattern": "periodic", "waveform": "cos", "patternAxis": "u", "patternWavelength": 0.01,
    "samplingMethod": "antithetic",
    "useSingleChannel": True, "singleChannel": "luminance",
})
graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})

graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Tracer.color", "Accumulate.input")
graph.mark_output("Accumulate.output")
testbed.render_graph = graph

# 3. Render
for _ in range(1024):  # 1024 frames x 8 spp = 8192 spp
    testbed.frame()

# 4. Save the image
image = graph.get_output("Accumulate.output").to_numpy()[..., 0]  # one channel (luminance)
np.save("structured_light.npy", image)
# The measurement is signed: show it with a diverging colormap, 0 in white.
limit = np.percentile(np.abs(image), 95)
plt.imsave("structured_light.png", image, cmap="bwr", vmin=-limit, vmax=limit)
