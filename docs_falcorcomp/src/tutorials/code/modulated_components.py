"""The parts of a modulated-light measurement of the Cornell box, side by side.

Usage: python modulated_components.py [cwtof | structured_light]

Renders (1) the full measurement with the unsigned modulation, in [0, 1] (direct + indirect light, RGB),
(2) the same with the indirect light only, and (3) the signed, zero-mean measurement of the tutorial, in
[-1, 1] (indirect only), and saves them next to each other.
"""
import sys

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

MEASUREMENT = sys.argv[1] if len(sys.argv) > 1 else "cwtof"
FRAMES = 1024  # 1024 frames x 8 spp = 8192 spp per image

# The tracer and its options, as in the CW-ToF and structured light tutorials.
if MEASUREMENT == "cwtof":
    TRACER = "CWToFPathTracerInline"
    OPTIONS = {"samplesPerPixel": 8, "maxBounces": 3,
               "waveform": "cos", "modulationWavelength": 0.01, "phase": 0.0,
               "useAntitheticSampling": True}
else:
    TRACER = "StructuredLightPathTracerInline"
    OPTIONS = {"samplesPerPixel": 8, "maxBounces": 3,
               "projectorPosition": [0.4, 1.0, 6.8], "projectorDirection": [0.0, 0.0, -1.0],
               "projectorFov": [30.0, 30.0], "projectorIntensity": [10.0, 10.0, 10.0],
               "pattern": "periodic", "waveform": "cos", "patternAxis": "u", "patternWavelength": 0.01,
               "samplingMethod": "antithetic"}


def render(properties):
    graph = testbed.create_render_graph(MEASUREMENT)
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Tracer", TRACER, {**OPTIONS, **properties})
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    if MEASUREMENT == "cwtof":  # a point light at the camera
        graph.create_pass("Light", "LaserLight", {
            "isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0],
        })
        graph.add_edge("Light", "Tracer")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    testbed.render_graph = graph
    for _ in range(FRAMES):
        testbed.frame()
    return graph.get_output("Accumulate.output").to_numpy()[..., :3]


full = render({"unsignedModulation": True, "computeDirect": True})
indirect = render({"unsignedModulation": True, "computeDirect": False})
signed = render({"unsignedModulation": False, "computeDirect": False,
                 "useSingleChannel": True, "singleChannel": "luminance"})[..., 0]


def to_display(image, exposure):
    image = np.maximum(image, 0.0) * exposure
    return np.clip(image / (1.0 + image), 0, 1) ** (1 / 2.2)


# The two RGB images share one exposure, set by the full measurement, so their brightness compares.
exposure = 1.0 / np.percentile(full.mean(axis=-1), 99)
limit = np.percentile(np.abs(signed), 95)
figure, axes = plt.subplots(1, 3, figsize=(12, 4.3))
axes[0].imshow(to_display(full, exposure))
axes[0].set_title("modulation in [0, 1]: direct + indirect")
axes[1].imshow(to_display(indirect, exposure))
axes[1].set_title("modulation in [0, 1]: indirect")
axes[2].imshow(signed, cmap="bwr", vmin=-limit, vmax=limit)
axes[2].set_title("modulation in [-1, 1]: indirect")
for axis in axes:
    axis.set_xticks([])
    axis.set_yticks([])
figure.tight_layout()
figure.savefig(f"{MEASUREMENT}_components.png", dpi=100)
