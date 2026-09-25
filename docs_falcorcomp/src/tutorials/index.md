# ToF rendering

Time-of-flight (ToF) imaging lights the scene with a short laser pulse and records when the light
comes back to the sensor. Light travels at a constant speed, so its arrival time is set by the
total length of its path: laser -> scene -> camera. falcorcomp renders ToF measurements by tracking
the length of every light path it samples. Path lengths are in scene units.

These tutorials render two kinds of ToF measurements:

| Measurement | Output | Render pass |
|---|---|---|
| **Time-gated image** | `H × W` image of the light whose path length falls inside a gate of width `timeGateWindow`, centered between `timeMin` and `timeMax` | `TimeGatedPathTracerInline`, `TimeGatedReSTIRInline` |
| **Transient histogram** | `H × W × B` histogram: for every pixel, the light arriving at each path length, in `timeBin` bins from `timeMin` to `timeMax` | `TransientHistogramPathTracerInline` |

All the tutorials use the same scene and a similar render graph:

- **Scene:** the Cornell box without its area light, so the laser is the only light. The laser
  sits in front of the box at `(0, 1.7, 6.8)` and points into it.
- **Render graph:** `VBufferRT` finds the camera's primary hits, `LaserVBufferRT` places the
  laser and finds where its beam hits the scene, and the ToF render pass traces paths from the
  camera and connects them to the laser spot. The frames are then averaged (`AccumulatePass` or
  `TransientHistogramAccumulatePass`) or shown (`ToneMapper`, `TransientHistogramViewer`).

Each tutorial is a short Python script, explained step by step, with the full script at the end.
The **offline** tutorials render without a window and save the result to a file. The **online**
tutorials open an interactive window, where the result converges over frames and the camera and
the settings can be changed while it runs.

Before you start:

- Install falcorcomp (see [Installation](../getting_started/installation.md)).
- Download the scene, {download}`scene-v4-nolight.pbrt <scenes/cornell-box/scene-v4-nolight.pbrt>`,
  and save it as `cornell-box/scene-v4-nolight.pbrt` next to the scripts. (The Cornell box is by
  Benedikt Bitterli, released under {download}`CC0 <scenes/cornell-box/LICENSE.txt>`.)

## Time-gated rendering

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Time-gated rendering (offline)
:img-top: images/thumbnails/time_gated_offline_thumb.jpg
:img-alt: Time-gated Cornell box
:link: time_gated_offline
:link-type: doc

Render a time-gated image with `TimeGatedPathTracerInline`, average the frames, and save it as
EXR and PNG.
```

```{grid-item-card} Time-gated rendering (online)
:img-top: images/thumbnails/time_gated_online_thumb.jpg
:img-alt: The time-gated Cornell box in its window
:link: time_gated_online
:link-type: doc

Show the time-gated image in an interactive window, and change the gate, the sampling and the
camera while it renders.
```

```{grid-item-card} Time-gated ReSTIR (offline)
:img-top: images/thumbnails/time_gated_restir_offline_thumb.jpg
:img-alt: Time-gated Cornell box rendered with TG ReSTIR
:link: time_gated_restir_offline
:link-type: doc

Render a narrow gate with `TimeGatedReSTIRInline`, which reuses paths across pixels, and compare
it with the path tracer at equal rendering time.
```
````

## Transient rendering

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Transient rendering (offline)
:img-top: images/thumbnails/transient_offline_thumb.jpg
:img-alt: Bins of the Cornell box's transient histogram
:link: transient_offline
:link-type: doc

Render a 64-bin transient histogram with `TransientHistogramPathTracerInline`, save it as a NumPy
array, and save 16 of its bins as an image grid.
```

```{grid-item-card} Transient rendering (online)
:img-top: images/thumbnails/transient_online_thumb.jpg
:img-alt: The transient histogram window
:link: transient_online
:link-type: doc

Browse the histogram in an interactive window with `TransientHistogramViewer`, and plot a
pixel's transient profile.
```
````

```{toctree}
:hidden:

time_gated_offline
time_gated_online
time_gated_restir_offline
transient_offline
transient_online
```
