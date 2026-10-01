# Event camera (offline)

This tutorial simulates an event camera moving forward through the Cornell box at 1000 frames per second, and renders
the brightness change between two frames with 1024 samples per pixel per frame, two ways:

- **Path tracer:** each frame with its own random numbers (`EventDifference`, `sampling = independent`).
- **Correlated path tracer:** each frame rendered twice, once with the previous frame's random numbers, so that the
  difference compares renders with the same random numbers (`sampling = correlated`; see
  [Correlated sampling](#event-correlated-sampling)).

It uses the scene described in [Event camera rendering](event_index.md).

```{image} images/event_camera.jpg
:alt: Primal image, intensity change, brightness change and events of path tracing with independent and with correlated random numbers
:align: center
```

## 1. Load the scene

The camera moves 2 mm per frame along its view direction. Events fire when the brightness changes by the threshold
$C = 0.2$.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`GBufferRT` finds the primary hits at the pixel centers; one `PathTracer` (independent) or two (correlated) render
from them. `EventDifference` keeps the previous frame and outputs the image, $\Delta I$ and $\Delta L$;
`EventGenerator` turns $\Delta L$ into events. `PathTracer` renders at most 16 samples per pixel, so
`EventDifference` averages several executions into one frame (`subframes`).

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render two frames"
```

## 3. Render two frames

Before every execution, the script sets the seeds of the path tracers, which fix their random numbers. With
correlated sampling, `TracerA` uses the previous frame's seed of the same execution and `TracerB` a new one, so
every render of frame 1 has a partner in frame 0 with the same random numbers. The difference needs only the
previous frame, so two frames are enough.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 3. Render two frames"
:end-before: "# 4. Show"
```

## 4. Compare

Both rows render 1024 samples per pixel per frame, and their images look the same. Their differences do not:

- **Path tracer:** $\Delta I$ is the difference of two independent noisy images, and at 1024 samples per pixel the
  noise still hides the change, most of all on the dark boxes in $\Delta L$; events fire all over the image (0.18 per
  pixel).
- **Correlated path tracer:** the noise of the two renders cancels, and $\Delta I$ shows the change: along the edges
  of the walls, the boxes and the light, and a slow change of the walls' shading. Events fire mostly along the edges
  and the light (0.013 per pixel).

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 4. Show"
```

The full script: {download}`event_camera_offline.py <code/event_camera_offline.py>`. It takes about 30 seconds.
Rendering at a few samples per pixel, as for long sequences, needs denoising: see
[Event rendering with denoising](event_denoising_index.md).
