# Event camera (offline)

This tutorial simulates an event camera moving forward through the Cornell box at 1000 frames per second. It renders
the brightness change of every frame three ways, each with 2 samples per pixel per frame, and compares them with a
reference:

- **Path tracer:** every frame with new random numbers, differenced with `EventDifference`.
- **Correlated path tracer:** every frame rendered twice, reusing the previous frame's seed, differenced with
  `EventDifference` (see [Correlated sampling](#event-correlated-sampling)).
- **EventSVGF:** the same two renders, with the difference denoised by `EventSVGF`.

It uses the scene described in [Event camera rendering](event_index.md).

```{image} images/event_camera.jpg
:alt: Primal image, intensity change, brightness change and events of path tracing, correlated path tracing, EventSVGF and a reference
:align: center
```

## 1. Load the scene

The camera moves 2 mm per frame along its view direction. Events fire when the brightness changes by the threshold
$C = 0.2$.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graphs"
```

## 2. Build the render graphs

`GBufferRT` finds the primary hits at the pixel centers; one `PathTracer` (path tracer) or two (correlated) render
from them. `EventDifference` or `EventSVGF` turns the renders into the frame's change, and `EventGenerator` turns
the brightness change into events. `EventSVGF` also takes the albedo, emission, depth, normal and motion vectors of
the primary hits.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 2. Build the render graphs"
:end-before: "# 3. Render the camera path"
```

## 3. Render the camera path

Before every frame, the script moves the camera and sets the seeds: with correlated sampling, `TracerA` reuses the
previous frame's seed and `TracerB` takes a new one. After 30 frames, it reads the last frame's outputs.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 3. Render the camera path"
:end-before: "# 4. Reference"
```

## 4. Reference

The reference is the correlated difference of the last two frames with 4096 + 4096 samples per pixel:
`EventDifference` averages 256 executions of 16 samples into each frame (`subframes`), each with its own pair of
seeds.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 4. Reference"
:end-before: "# 5. Show"
```

## 5. Compare

Each row shows the frame's image, $\Delta I$, $\Delta L$ and the events, with the number of events per pixel where
the reference has none.

- **Path tracer:** the difference of two independent noisy images is noise, and events fire everywhere (about 8
  false events per pixel).
- **Correlated path tracer:** most of the noise cancels, and $\Delta I$ already has the reference's structure. What
  remains are rare large differences, where a bounce with the same random numbers reaches a different object in the
  next frame; they are densest where the walls meet (0.05 false events per pixel).
- **EventSVGF:** those are filtered out, leaving 0.008 false events per pixel. Its image is gray because it filters
  the luminance only.

```{literalinclude} code/event_camera_offline.py
:language: python
:start-after: "# 5. Show"
```

The full script: {download}`event_camera_offline.py <code/event_camera_offline.py>`. It takes about a minute, most
of it for the reference.
