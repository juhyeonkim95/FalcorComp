# Overview

falcorcomp is a collection of Monte Carlo renderers for computational imaging, built on the
[NVIDIA Falcor](https://github.com/NVIDIAGameWorks/Falcor) rendering framework. It is not a
general-purpose renderer: it provides render passes that simulate *active sensing* systems, which
light the scene themselves and measure what comes back, such as time-of-flight cameras and
structured light.

All renderers run on the GPU with hardware ray tracing, fast enough for interactive, real-time
simulation as well as for offline rendering. falcorcomp is installed as a Python package and
driven from Python scripts.

## What it renders

Time-of-flight (ToF): a laser lights the scene, and the measurement depends on the total length of
each light path (laser -> scene -> camera), which sets its arrival time.

| Measurement | Output | Render passes |
|---|---|---|
| **Time-gated image** | `H × W`: the light whose path length falls inside a time gate | [`TimeGatedPathTracerInline`](../plugin_reference/time_gated/TimeGatedPathTracerInline.md), [`TimeGatedReSTIRInline`](../plugin_reference/time_gated/TimeGatedReSTIRInline.md) |
| **Transient histogram** | `H × W × B`: for every pixel, the light arriving at each path length, in `B` bins | [`TransientHistogramPathTracerInline`](../plugin_reference/transient/TransientHistogramPathTracerInline.md), [`TransientHistogramReSTIRInline`](../plugin_reference/transient/TransientHistogramReSTIRInline.md) |

Modulated light: the light varies in time or in space, and the measurement weights each path by
that modulation.

| Measurement | Modulation | Render pass |
|---|---|---|
| **Continuous-wave ToF** | a periodic function of the path length | [`CWToFPathTracerInline`](../plugin_reference/modulated/CWToFPathTracerInline.md) |
| **Structured light** | a projected pattern | [`StructuredLightPathTracerInline`](../plugin_reference/modulated/StructuredLightPathTracerInline.md) |

The ToF measurements have a path tracer and a ReSTIR renderer each. The ReSTIR renderers reuse the
paths found by neighboring pixels and by earlier frames, moved to each pixel with a
path-length-aware shift mapping, which pays off when few sampled paths fit the measurement, such as
with a narrow time gate or in online rendering. The modulated-light renderers support antithetic
sampling, which pairs every sampled path with a nearby one of opposite modulation, so that the
indirect light cancels the way it does in the real measurement.

Event camera and Doppler rendering are coming.

## How it is used

A script loads a scene, builds a Falcor *render graph* around one of the render passes and renders
frames with it:

```python
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0

graph = testbed.create_render_graph("TimeGated")
graph.create_pass("VBuffer", "VBufferRT", {})                     # primary hits
graph.create_pass("Laser", "LaserLight", {                        # the laser
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0],
    "laserPower": [170.0, 120.0, 40.0],
})
graph.create_pass("Tracer", "TimeGatedPathTracerInline", {        # the ToF render pass
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeGateWindow": 0.1, "timeCenter": 17.337,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("Laser", "Tracer")                                 # run the laser pass first
graph.mark_output("Tracer.color")
testbed.render_graph = graph

testbed.frame()                                                   # one noisy frame; average many for a clean image
image = graph.get_output("Tracer.color").to_numpy()               # 512 x 512 x RGBA
```

The same graph can run in an interactive window, where the camera and the render pass's settings
can be changed while it renders. The [tutorials](../tutorials/index.md) build such graphs step by
step, and the [plugin reference](../plugin_reference/time_gated.md) describes every render pass and
its settings.

## Research

falcorcomp includes the implementations of these papers:

- **ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling**, SIGGRAPH 2026
  (ACM TOG). [Project page](https://juhyeonkim95.github.io/project-pages/tof_restir/). The ReSTIR
  render passes for time-gated and transient rendering.
- **Difference-aware Filtering for Event Camera Simulation**, EGSR 2026 (Computer Graphics Forum).
  [Project page](https://juhyeonkim95.github.io/project-pages/event_svgf/). Low-sample event camera
  rendering (coming to falcorcomp).
- **Geometric Antithetic Sampling for Spatiotemporally Modulated Light**, SIGGRAPH Asia 2026.
  Antithetic sampling in the CW-ToF and structured light render passes.

If falcorcomp is useful in your research, please cite the corresponding papers; the BibTeX entries
are in the [README](https://github.com/juhyeonkim95/FalcorComp#citation).

## Next steps

- [Installation](installation.md): install the Python package.
- [Tutorials](../tutorials/index.md): render time-gated images, transient histograms, CW-ToF and
  structured light measurements.
- [Advanced tutorials](../tutorials/restir_index.md): ReSTIR and ellipsoidal sampling.
