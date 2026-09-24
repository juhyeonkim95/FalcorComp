"""Transient histogram graph and storage conventions (H, W, B; red channel)."""
import numpy as np


METHODS = ("pt", "kde", "tri_approx")


def create_histogram_graph(testbed, scene, method, spp, bins, initial_window_ratio):
    graph = testbed.create_render_graph("histogram_" + method)
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True})
    graph.create_pass("Laser", "LaserVBufferRT", {
        "samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True,
        "laserPosition": scene.light_position, "laserDirection": scene.light_direction,
        "laserPower": scene.light_power, "laserAngle": scene.light_angle_degrees,
        "laserCollocated": False, "isLightSourceLaser": scene.is_laser,
    })
    graph.create_pass("Tracer", "TransientHistogramPathTracerInline", {
        "samplingMethod": "tri_approx" if method == "tri_approx" else "direct",
        "useKernelDensityEstimation": method == "kde",
        "timeGateMode": "epanechnikov" if method == "kde" else "box",
        "initialWindowRatio": initial_window_ratio,
        "samplesPerPixel": spp, "maxBounces": scene.max_bounces,
        "computeDirect": False, "useImportanceSampling": True, "useAlphaTest": True,
        "useSingleChannel": True,
        "timeMin": scene.gate_min, "timeMax": scene.gate_max, "timeBin": bins,
    })
    for source, target in (("VBuffer.vbuffer", "Tracer.vbuffer"), ("VBuffer.viewW", "Tracer.viewW"),
                           ("Laser.vbuffer", "Tracer.laservbuffer"), ("Laser.viewW", "Tracer.laserviewW")):
        graph.add_edge(source, target)
    graph.mark_output("Tracer.histogram")
    testbed.render_graph = graph
    return graph


def histogram_to_hwb(raw, resolution, bins):
    raw = np.asarray(raw)
    expected = (bins, resolution[1], resolution[0])
    if raw.shape == (*expected, 1):
        raw = raw[..., 0]
    if raw.shape != expected or not np.isfinite(raw).all():
        raise ValueError(f"Expected finite B x H x W histogram {expected}, got {raw.shape}")
    return np.ascontiguousarray(raw.transpose(1, 2, 0))


def load_histogram(path, resolution, bins):
    values = np.load(path, mmap_mode="r", allow_pickle=False)
    if values.shape != (resolution[1], resolution[0], bins) or not np.isfinite(values).all():
        raise ValueError(f"Invalid H x W x B histogram: {path}")
    return values
