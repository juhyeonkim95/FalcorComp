"""Smoke test of an installed falcorcomp wheel: renders the main passes for a few frames on the tutorials' Cornell box
(.pbrt), then on its .pyscene version (PythonImporter, PLY meshes). Checks that the outputs are finite and not all
zero, and that every property is known; prints the md5 of each output, which the wheels of all Python versions on one
platform should share.

Install the wheel into a fresh environment and run

    python packaging/falcorcomp/tests/smoke_test.py [<tutorials scenes folder>] [--device vulkan] [--each]

It imports the installed package (this folder, not packaging/falcorcomp, is on sys.path). The scenes default to
docs_falcorcomp/src/tutorials/scenes of this repository. A failing graphics API call ends the process, so --each runs
every case in its own process to report all of them.
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

import numpy as np

import falcorcomp as falcor

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
# The last case: the first one on the .pyscene version of the scene.
PYSCENE_CASE = len(CASES)


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


def run_each(args):
    """Runs every case in its own process; returns whether all passed."""
    ok = True
    for case in range(PYSCENE_CASE + 1):
        command = [sys.executable, __file__, str(args.scenes), "--device", args.device, "--case", str(case)]
        result = subprocess.run(command + (["--debug-layers"] if args.debug_layers else []), capture_output=True,
                                text=True, errors="replace")
        lines = (result.stdout + result.stderr).splitlines()
        if case == 0:
            print(next((line for line in lines if line.startswith("Device: ")), ""), flush=True)
        if result.returncode == 0:
            print(next(line for line in lines if "md5=" in line), flush=True)
        else:
            ok = False
            name = CASES[case % PYSCENE_CASE][0] + (" (pyscene)" if case == PYSCENE_CASE else "")
            print(f"{name:36s} FAILED (exit code {result.returncode}):", flush=True)
            # Errors and Falcor's fatal message, without the shader compiler's warnings.
            for line in [line for line in lines if any(key in line for key in ["(Error)", "(Fatal)", "Error:"])][:10]:
                print(f"    {line}", flush=True)
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenes", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[3] / "docs_falcorcomp/src/tutorials/scenes")
    parser.add_argument("--device", choices=["default", "d3d12", "vulkan"], default="default")
    parser.add_argument("--debug-layers", action="store_true", help="enable the D3D12 or Vulkan validation layers")
    parser.add_argument("--each", action="store_true", help="run every case in its own process")
    parser.add_argument("--case", type=int, help="run only this case (the last one is the .pyscene)")
    args = parser.parse_args()

    print(f"falcorcomp {falcor.__version__} from {Path(falcor.__file__).parent}", flush=True)
    if args.each:
        ok = run_each(args)
    else:
        falcor.Logger.verbosity = falcor.Logger.Level.Warning
        device_type = {"default": falcor.DeviceType.Default, "d3d12": falcor.DeviceType.D3D12,
                       "vulkan": falcor.DeviceType.Vulkan}[args.device]
        testbed = falcor.Testbed(create_window=False, device_type=device_type, enable_debug_layers=args.debug_layers)
        info = testbed.device.info
        print(f"Device: {info.api_name} on {info.adapter_name}", flush=True)
        testbed.clock.pause()
        cases = range(PYSCENE_CASE + 1) if args.case is None else [args.case]
        ok = True
        if any(case < PYSCENE_CASE for case in cases):
            load(testbed, args.scenes / "cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
            for case in [case for case in cases if case < PYSCENE_CASE]:
                ok &= render(testbed, case, *CASES[case])
        if PYSCENE_CASE in cases:
            print("pyscene:", flush=True)
            load(testbed, args.scenes / "cornell-box-moving/scene.pyscene",
                 falcor.SceneBuilderFlags.DontMergeMaterials | falcor.SceneBuilderFlags.DontOptimizeGraph)
            ok &= render(testbed, PYSCENE_CASE, *CASES[0])
    print(f"falcorcomp {falcor.__version__}: {'SMOKE OK' if ok else 'SMOKE FAILED'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
