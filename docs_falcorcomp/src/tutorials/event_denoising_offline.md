# Event rendering with denoising (offline)

This tutorial renders the event camera of [Event camera (offline)](event_camera_offline.md), moving forward through
the Cornell box, at a few samples per pixel per frame over 30 frames, and compares five methods with a reference:

- **Path tracer** (4 spp): each frame with its own random numbers.
- **Correlated path tracer** (2 + 2 spp): each frame rendered twice, reusing the previous frame's seed.
- **OptiX denoiser** and **SVGF** (2 spp): each frame's image denoised, then differenced.
- **EventSVGF** (1 + 1 spp): the correlated difference, denoised.

The sample counts follow the paper, where they take about the same time per frame; at 1024 × 1024 on an RTX 3090,
the whole graph took about 6.9, 7.4, 7.5, 5.1 and 4.6 ms per frame. It uses the scene described in
[Event camera rendering](event_index.md).

```{image} images/event_denoising.jpg
:alt: Primal image, intensity change, brightness change and events of path tracing, correlated path tracing, OptiX, SVGF, EventSVGF and a reference
:align: center
```

## 1. Load the scene

```{literalinclude} code/event_denoising_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graphs"
```

## 2. Build the render graphs

All methods share `GBufferRT` and `EventGenerator`:

- the path tracers feed `EventDifference` directly;
- the primal denoisers take one `PathTracer`'s render with its albedo, normals and motion vectors, and their output
  feeds `EventDifference` (`independent`);
- `EventSVGF` takes the two correlated renders, the albedo, emission, depth, normal and motion vectors, and replaces
  `EventDifference`.

The denoisers are temporal: they reuse earlier frames along the motion vectors, so the script renders a sequence.

```{literalinclude} code/event_denoising_offline.py
:language: python
:start-after: "# 2. Build the render graphs"
:end-before: "# 3. Render the camera path"
```

## 3. Render the camera path

Every method renders the same 30 frames; the seeds are set before every frame, as in
[Event camera (offline)](event_camera_offline.md).

```{literalinclude} code/event_denoising_offline.py
:language: python
:start-after: "# 3. Render the camera path"
:end-before: "# 4. Reference"
```

## 4. Reference

The correlated difference of the last two frames with 4096 + 4096 samples per pixel.

```{literalinclude} code/event_denoising_offline.py
:language: python
:start-after: "# 4. Reference"
:end-before: "# 5. Show"
```

## 5. Compare

Each row shows the last frame's image, $\Delta I$, $\Delta L$ and the events, with the number of events per pixel
where the reference has none:

- **Path tracer:** noise everywhere (5.5 false events per pixel).
- **Correlated path tracer:** the change is visible, with rare large differences where a bounce with the same random
  numbers reaches a different object in the next frame (0.042).
- **OptiX denoiser:** the images are clean, but their residual errors change from frame to frame, and the difference
  shows them as large blobs; the false events trace the box and wall edges (0.096).
- **SVGF:** smaller, smoother blobs, and noise along the walls (0.062).
- **EventSVGF:** close to the reference, with 0.0079 false events per pixel. Its image is gray because it filters the
  luminance only.

```{literalinclude} code/event_denoising_offline.py
:language: python
:start-after: "# 5. Show"
```

The full script: {download}`event_denoising_offline.py <code/event_denoising_offline.py>`. It takes about 90
seconds, most of it for the reference.
