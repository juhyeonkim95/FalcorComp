"""Smoke test of an installed falcorcomp wheel: renders the main passes for a few frames on the tutorials' Cornell box
(.pbrt), then on its .pyscene version (PythonImporter, PLY meshes). Checks that the outputs are finite and not all
zero, and that every property is known; prints the md5 of each output, which the wheels of all Python versions on one
platform should share.

Install the wheel into a fresh environment and run

    python packaging/falcorcomp/tests/smoke_test.py [<tutorials scenes folder>]

It imports the installed package (this folder, not packaging/falcorcomp, is on sys.path). The scenes default to
docs_falcorcomp/src/tutorials/scenes of this repository.
"""
import hashlib
import sys
from pathlib import Path

import numpy as np

import falcorcomp as falcor

SCENES = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3] / \
    "docs_falcorcomp/src/tutorials/scenes"
LASER = {"laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0], "laserPower": [170.0, 120.0, 40.0]}
GATE = {"timeCenter": 17.337, "timeGateWindow": 0.1, "computeDirect": False}
CASES = [
    ("TimeGatedPathTracerInline", {**GATE, "samplesPerPixel": 4}, "color"),
    ("TimeGatedReSTIRInline", {**GATE, "samplesPerPixel": 4, "shiftMappingMethod": "local_tangent",
                               "gaugeMode": "avg_grad", "useTemporalReuse": True}, "color"),
    ("TransientHistogramPathTracerInline", {"timeMin": 16.75, "timeMax": 18.03, "timeBin": 16, "samplesPerPixel": 4},
     "histogram"),
    ("CWToFPathTracerInline", {"samplesPerPixel": 4, "modulationWavelength": 0.05}, "color"),
    ("StructuredLightPathTracerInline", {"samplesPerPixel": 4, "samplingMethod": "naive"}, "color"),
    ("StructuredLightPathTracerInline", {"samplesPerPixel": 4, "samplingMethod": "antithetic"}, "color"),
    ("InlinePathTracer", {"samplesPerPixel": 4, "maxBounces": 3, "computeDirect": True}, "color"),
]


def load(testbed, path, flags):
    testbed.load_scene(str(path), flags)
    testbed.resize_frame_buffer(128, 128)
    testbed.scene.camera.aspectRatio = 1.0


def render(testbed, index, kind, props, output):
    """Renders three frames; returns whether the output is finite and not all zero, and every property known."""
    graph = testbed.create_render_graph(f"Smoke{index}")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    graph.create_pass("Laser", "LaserLight", LASER)
    tracer = graph.create_pass("Tracer", kind, props)
    unknown = [k for k in props if k not in tracer.properties and k != "timeCenter"]
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Laser", "Tracer")
    if "ReSTIR" in kind:
        graph.add_edge("VBuffer.mvec", "Tracer.mvec")
    graph.mark_output(f"Tracer.{output}")
    testbed.render_graph = graph
    for _ in range(3):
        testbed.frame()
    image = graph.get_output(f"Tracer.{output}").to_numpy()
    finite, nonzero = bool(np.isfinite(image).all()), bool(np.any(image))
    digest = hashlib.md5(image.tobytes()).hexdigest()[:12]
    mean = float(image[..., :3].mean() if image.ndim == 3 else image.mean())
    print(f"{kind:36s} {props.get('samplingMethod', ''):10s} finite={finite} nonzero={nonzero} unknown={unknown} "
          f"md5={digest} mean={mean:.5g}", flush=True)
    return finite and nonzero and not unknown


print(f"falcorcomp {falcor.__version__} from {Path(falcor.__file__).parent}", flush=True)
falcor.Logger.verbosity = falcor.Logger.Level.Warning
testbed = falcor.Testbed(create_window=False)
testbed.clock.pause()
ok = True
load(testbed, SCENES / "cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
for i, case in enumerate(CASES):
    ok &= render(testbed, i, *case)
print("pyscene:", flush=True)
load(testbed, SCENES / "cornell-box-moving/scene.pyscene",
     falcor.SceneBuilderFlags.DontMergeMaterials | falcor.SceneBuilderFlags.DontOptimizeGraph)
ok &= render(testbed, len(CASES), *CASES[0])
print(f"falcorcomp {falcor.__version__}: {'SMOKE OK' if ok else 'SMOKE FAILED'}")
sys.exit(0 if ok else 1)
