"""Offline transient histogram rendering of the Cornell box with TransientHistogramPathTracerInline."""

# 1. Load the scene
import falcorcomp as falcor
import numpy as np
from PIL import Image

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(256, 256)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# 2. Build the render graph
T_MIN, T_MAX, BINS = 16.75, 18.03, 64

graph = testbed.create_render_graph("Transient")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserVBufferRT", {
    "samplePattern": "Center", "sampleCount": 1,
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0,
})
graph.create_pass("Tracer", "TransientHistogramPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6, "computeDirect": False,
    "timeMin": T_MIN, "timeMax": T_MAX, "timeBin": BINS,
})

graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
graph.add_edge("Laser.viewW", "Tracer.laserviewW")
graph.create_pass("Accumulate", "TransientHistogramAccumulatePass", {})
graph.add_edge("Tracer.histogram", "Accumulate.input")
graph.mark_output("Accumulate.output")
testbed.render_graph = graph

# 3. Render
FRAMES = 256  # 256 frames x 16 spp = 4096 spp
for _ in range(FRAMES):
    testbed.frame()

# 4. Read the histogram
# The mean over the frames, in radiance per unit path length.
histogram = graph.get_output("Accumulate.output").to_numpy()[..., :3]  # (bins, height, width, RGB)
np.save("transient.npy", histogram)

# 5. Show 16 bins in a 4 x 4 grid
bins = np.linspace(0, BINS - 1, 16).round().astype(int)
tiles = histogram[bins] * (T_MAX - T_MIN)  # radiance if all light arrived in that bin
height, width = tiles.shape[1:3]
grid = tiles.reshape(4, 4, height, width, 3).transpose(0, 2, 1, 3, 4).reshape(4 * height, 4 * width, 3)
display = (np.clip(grid / (1 + grid), 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
Image.fromarray(display).save("transient_grid.png")
