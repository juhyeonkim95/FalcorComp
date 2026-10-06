# Overview

falcorcomp is a collection of Monte Carlo renderers for computational imaging, built on the
[NVIDIA Falcor](https://github.com/NVIDIAGameWorks/Falcor) rendering framework. It is not a
general-purpose renderer: it provides render passes that simulate *active sensing* systems, which
light the scene themselves and measure what comes back, such as time-of-flight cameras and
structured light.

falcorcomp is **performance-oriented**: all renderers run on the GPU with hardware ray tracing,
fast enough for interactive, real-time simulation as well as for offline rendering. falcorcomp is
installed as a Python package and driven from Python scripts.

## What it renders

```{image} images/overview_outputs.jpg
:alt: The Cornell box as a standard image, a time-gated image, a transient histogram, CW-ToF and structured-light measurements, a Doppler spectrum, a Doppler-gated image, a Doppler ToF velocity map and camera events
:align: center
```

The Cornell box rendered with falcorcomp. Left: a standard image. Top row: a time-gated image, a transient histogram
(16 of its 64 bins), and CW-ToF and structured-light measurements. Bottom row, with the tall box approaching and the
short box receding: the Doppler spectrum of optical heterodyne detection (4 of its bins), a Doppler-gated image (only
the light shifted by about +26 MHz: the tall box), the velocity estimated from Doppler ToF measurements (red
approaching, blue receding), and the events of a camera moving right (red brighter, blue darker). The settings follow
the [tutorials](../tutorials/index.md). [Measurements as path integrals](measurements.md) gives the path integral of
each.

- **Time-of-flight (ToF)**: a laser lights the scene, and the measurement depends on the total length of each light
  path (laser -> scene -> camera), which sets its arrival time.

| Measurement | Output | Render passes |
|---|---|---|
| **Time-gated image** | `H × W`: the light whose path length falls inside a time gate | [`TimeGatedPathTracerInline`](../plugin_reference/time_gated/TimeGatedPathTracerInline.md), [`TimeGatedReSTIRInline`](../plugin_reference/time_gated/TimeGatedReSTIRInline.md) |
| **Transient histogram** | `H × W × B`: for every pixel, the light arriving at each path length, in `B` bins | [`TransientHistogramPathTracerInline`](../plugin_reference/transient/TransientHistogramPathTracerInline.md), [`TransientHistogramReSTIRInline`](../plugin_reference/transient/TransientHistogramReSTIRInline.md) |

- **Modulated light**: the light varies in time or in space, and the measurement weights each path by that
  modulation.

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

- **Doppler**: the measurement depends on how fast each path's length changes as the scene moves (with FMCW, also on
  the length itself).

| Measurement | Output | Render pass |
|---|---|---|
| **Doppler-gated image (OHD)** | `H × W`: the light whose Doppler shift falls inside a gate | [`DopplerGatedPathTracerInline`](../plugin_reference/doppler/DopplerGatedPathTracerInline.md) |
| **Doppler spectrum (OHD)** | `H × W × B`: for every pixel, the light at each Doppler shift, in `B` bins | [`DopplerHistogramPathTracerInline`](../plugin_reference/doppler/DopplerHistogramPathTracerInline.md) |
| **FMCW spectra (OHD)** | `H × W × B`, for the up- and the down-chirp: the light at each beat frequency, which depends on the path length and the Doppler shift | [`DopplerHistogramPathTracerInline`](../plugin_reference/doppler/DopplerHistogramPathTracerInline.md) with a chirp |
| **Doppler ToF** | `H × W`: a CW-ToF measurement with slightly different light and sensor frequencies, over an exposure in which the objects move | [`DopplerToFPathTracerInline`](../plugin_reference/doppler/DopplerToFPathTracerInline.md) |

- **Event cameras**: each pixel reports when its brightness $\log(I_\epsilon + I)$ changes by more than a
  threshold.

| Measurement | Output | Render passes |
|---|---|---|
| **Brightness change and events** | `H × W` per frame: the change $\Delta L$ since the previous frame, and the signed number of events | [`EventDifference`](../plugin_reference/event/EventDifference.md), [`EventSVGF`](../plugin_reference/event/EventSVGF.md), [`EventGenerator`](../plugin_reference/event/EventGenerator.md) |

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

A pass's settings can also be changed between frames, with the names used to create it:
`graph.get_pass("Tracer").set_properties({"timeCenter": 17.6})`. Settings left out keep their
values, an invalid value raises an error and leaves the pass unchanged, and
`graph.get_pass("Tracer").properties` returns the current settings.

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
  [Project page](https://juhyeonkim95.github.io/project-pages/event_svgf/). The `EventSVGF` render pass:
  low-sample event camera rendering.
- **Geometric Antithetic Sampling for Spatiotemporally Modulated Light**, SIGGRAPH Asia 2026.
  [Project page](https://juhyeonkim95.github.io/project-pages/antithetic_modulation/). Antithetic sampling in the
  CW-ToF and structured light render passes.
- **A Monte Carlo Rendering Framework for Simulating Optical Heterodyne Detection**, SIGGRAPH 2025 (ACM TOG),
  honorable mention. [Project page](https://juhyeonkim95.github.io/project-pages/ohd_rendering/). The OHD path
  integral behind the Doppler spectrum and Doppler-gated render passes.
- **Doppler Time-of-Flight Rendering**, SIGGRAPH Asia 2023 (ACM TOG).
  [Project page](https://juhyeonkim95.github.io/project-pages/dopplertof/). The Doppler ToF render pass.

If falcorcomp is useful in your research, please cite the corresponding papers; the BibTeX entries
are in the [README](https://github.com/juhyeonkim95/FalcorComp#citation).

## Next steps

- [Installation](installation.md): install the Python package.
- [Tutorials](../tutorials/index.md): render time-gated images, transient histograms, CW-ToF and
  structured light measurements.
- [Advanced tutorials](../tutorials/restir_index.md): ReSTIR and ellipsoidal sampling.
