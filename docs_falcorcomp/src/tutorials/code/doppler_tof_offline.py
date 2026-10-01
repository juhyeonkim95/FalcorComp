"""Doppler ToF velocity of the Cornell box with DopplerToFPathTracerInline, checked against VelocityGroundTruthInline."""
# 1. Load the scene
import falcorcomp as falcor
import numpy as np
import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt

testbed = falcor.Testbed(create_window=False)
# The boxes are built as animated (see scene.pyscene); keep every object separate and named.
testbed.load_scene("cornell-box-moving/scene.pyscene",
                   falcor.SceneBuilderFlags.DontMergeMaterials | falcor.SceneBuilderFlags.DontOptimizeGraph)
testbed.resize_frame_buffer(256, 256)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

# The tall box comes towards the camera (+z), the short box moves away, at 2 m/s.
VELOCITIES = {"TallBox": {"linear": [0.0, 0.0, 2.0]}, "ShortBox": {"linear": [0.0, 0.0, -2.0]}}
F_G, T = 30.0, 0.015  # light modulation (MHz) and exposure (s)
LIGHT = {"isLightSourceLaser": False, "laserCollocated": True, "laserPower": [10.0, 10.0, 10.0]}


# 2. Render a Doppler ToF measurement
def render(heterodyne_frequency, phase, renders):
    graph = testbed.create_render_graph("DopplerToF")
    graph.create_pass("Light", "LaserLight", LIGHT)
    properties = {
        "samplesPerPixel": 16, "maxBounces": 3, "computeDirect": True,
        "modulationFrequency": F_G, "heterodyneFrequency": heterodyne_frequency,
        "exposureTime": T, "phase": phase, "timeSampling": "stratified",
        "velocities": VELOCITIES,
    }
    if heterodyne_frequency != 0.0:
        # Pair every time t with t + 1 / (2 df), rendered with the same random numbers.
        properties.update({"antithetic": "half_period", "randomReplay": True})
    else:
        properties["antithetic"] = "none"  # without a heterodyne frequency there is no half period
    graph.create_pass("Tracer", "DopplerToFPathTracerInline", properties)
    # The tracer moves the scene every frame: keep AccumulatePass from restarting on scene changes.
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated", "autoReset": False})
    graph.add_edge("Light", "Tracer")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    testbed.render_graph = graph
    frames = renders // (2 if heterodyne_frequency != 0.0 else 1)  # a paired frame is two renders
    for _ in range(frames):
        testbed.frame()
    return graph.get_output("Accumulate.output").to_numpy()[..., :3].mean(-1)


# 3. Heterodyne and homodyne, at sensor phases 0 and 0.25
RENDERS = 4096
heterodyne = render(1.0 / T, 0.0, RENDERS) + 1j * render(1.0 / T, 0.25, RENDERS)
homodyne = render(0.0, 0.0, RENDERS) + 1j * render(0.0, 0.25, RENDERS)

# 4. Velocity from the ratio
# A path whose length changes at rate dl/dt has the frequency shift e = -f_g (dl/dt) / c, and
# heterodyne / homodyne = eT / (1 + eT). So eT = rho / (1 - rho) and v = -(1/2) dl/dt = c e / (2 f_g).
C = 299792458.0
valid = np.abs(homodyne) > 0.05 * np.percentile(np.abs(homodyne), 90)
rho = (heterodyne / np.where(valid, homodyne, np.nan)).real
velocity = C * (rho / (1 - rho) / T) / (2 * F_G * 1e6)
np.save("doppler_tof_velocity.npy", velocity)


# 5. Compare with the ground truth
def ground_truth(properties):
    graph = testbed.create_render_graph("Truth")
    graph.create_pass("Light", "LaserLight", LIGHT)
    graph.create_pass("Truth", "VelocityGroundTruthInline", {"velocities": VELOCITIES, **properties})
    graph.add_edge("Light", "Truth")
    graph.mark_output("Truth.velocity")
    testbed.render_graph = graph
    testbed.frame()
    return graph.get_output("Truth.velocity").to_numpy().reshape(velocity.shape)


panels = [
    (np.where(valid, velocity, np.nan), "estimated: heterodyne / homodyne"),
    (ground_truth({"mode": "path_length", "dt": 1e-3}), "D-ToF velocity: -(1/2) dl/dt"),
    (ground_truth({"mode": "doppler"}), "OHD velocity: u / 2"),
    (ground_truth({"mode": "projection", "direction": [0.0, 0.0, 1.0]}), "z velocity"),
]
figure, axes = plt.subplots(1, 4, figsize=(17, 4.3))
for axis, (image, title) in zip(axes, panels):
    shown = axis.imshow(image, cmap="bwr", vmin=-3, vmax=3)
    axis.set_title(title)
    axis.set_xticks([])
    axis.set_yticks([])
figure.colorbar(shown, ax=axes, fraction=0.012, label="m/s")
figure.savefig("doppler_tof_velocity.png", dpi=90, bbox_inches="tight")
