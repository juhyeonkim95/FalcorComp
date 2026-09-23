"""Render an offline time-gated image of the Cornell box with falcorcomp.

    pip install falcorcomp-0.1.0-cp310-cp310-linux_x86_64.whl
    python render_time_gated_cornell_box.py                 # ToF ReSTIR
    python render_time_gated_cornell_box.py --method pt     # path tracing

Writes <output>/<method>.exr (linear radiance) and <output>/<method>.png (tone mapped).
"""
import argparse
from pathlib import Path

import falcorcomp as falcor

HERE = Path(__file__).resolve().parent
SCENE = HERE.parent / "scene" / "cornell-box" / "scene-v4-nolight.pbrt"

# A collimated laser beside the camera, pointing into the box.
LASER = {"laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
         "laserPower": [170.0, 120.0, 40.0], "laserAngle": 0.0}


def build_graph(testbed, method, gate_center, gate_width, spp_per_frame):
    graph = testbed.create_render_graph("TimeGated")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True})
    graph.create_pass("Laser", "LaserVBufferRT", {"samplePattern": "Center", "sampleCount": 1, "useAlphaTest": True, **LASER})

    # A single time gate: a box of width gate_width centered at gate_center (path length units).
    tracer = {
        "samplesPerPixel": spp_per_frame, "maxBounces": 6, "computeDirect": False,
        "timeGateMode": "box", "timeGateWindow": gate_width,
        "timeMin": gate_center, "timeMax": gate_center, "timeBin": 1,
        "isLightSourceLaser": True, "laserCollocated": False,
    }
    if method == "pt":
        graph.create_pass("Tracer", "TimeGatedPathTracerInline", tracer)
    else:
        # Spatial reuse with path-length-aware shift mapping; no temporal reuse offline.
        tracer.update({
            "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
            "spatialReuseIteration": 3, "spatialReuseNeighborCount": 5, "spatialReuseGatherRadius": 10.0,
            "specularRoughnessThreshold": 0.05, "useTemporalReuse": False,
        })
        graph.create_pass("Tracer", "TimeGatedReSTIRInline", tracer)

    graph.create_pass("Accumulate", "AccumulatePass", {"enabled": True, "precisionMode": "SingleCompensated"})
    graph.create_pass("ToneMapper", "ToneMapper", {"autoExposure": False})
    for source, target in [("VBuffer.vbuffer", "Tracer.vbuffer"), ("VBuffer.viewW", "Tracer.viewW"),
                           ("Laser.vbuffer", "Tracer.laservbuffer"), ("Laser.viewW", "Tracer.laserviewW"),
                           ("Tracer.color", "Accumulate.input"), ("Accumulate.output", "ToneMapper.src")]:
        graph.add_edge(source, target)
    graph.mark_output("Accumulate.output")  # output 0: linear radiance
    graph.mark_output("ToneMapper.dst")     # output 1: tone mapped
    return graph


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--method", choices=["restir", "pt"], default="restir")
    parser.add_argument("--gate-center", type=float, default=17.337, help="gate center (path length)")
    parser.add_argument("--gate-width", type=float, default=0.1, help="gate width (path length)")
    parser.add_argument("--spp", type=int, default=256, help="total samples per pixel")
    parser.add_argument("--spp-per-frame", type=int, default=4)
    parser.add_argument("--resolution", type=int, nargs=2, default=[512, 512], metavar=("W", "H"))
    parser.add_argument("--scene", type=Path, default=SCENE)
    parser.add_argument("--output", type=Path, default=HERE / "output")
    args = parser.parse_args()

    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)
    testbed.load_scene(str(args.scene))
    testbed.resize_frame_buffer(*args.resolution)
    camera = testbed.scene.camera
    camera.aspectRatio = args.resolution[0] / args.resolution[1]
    camera.apertureRadius = 0.0
    testbed.clock.pause()

    testbed.render_graph = build_graph(testbed, args.method, args.gate_center, args.gate_width, args.spp_per_frame)
    frames = max(1, args.spp // args.spp_per_frame)
    for frame in range(frames):
        testbed.frame()
        if (frame + 1) % max(1, frames // 4) == 0:
            print(f"{args.method}: {(frame + 1) * args.spp_per_frame} spp", flush=True)

    args.output.mkdir(parents=True, exist_ok=True)
    testbed.capture_output(str(args.output / f"{args.method}.exr"), 0)
    testbed.capture_output(str(args.output / f"{args.method}.png"), 1)
    print(f"Saved {args.output / args.method}.exr and .png")


if __name__ == "__main__":
    main()
