# Time-gated ReSTIR (offline)

This tutorial renders the time-gated Cornell box from
[Time-gated rendering (offline)](time_gated_offline.md) with `TimeGatedReSTIRInline` instead of
the path tracer, and then compares the two at equal rendering time.

A narrow gate keeps only a small fraction of the paths a path tracer samples, so most pixels see
few paths that fit the gate and the image is noisy. `TimeGatedReSTIRInline` samples paths the
same way, but then lets every pixel *reuse* the paths found by its neighbors: each round of
spatial reuse resamples a few nearby pixels' paths, shifted to this pixel with a path-length-aware
shift mapping that keeps their length inside the gate. This tutorial uses a 0.02-wide gate, five
times narrower than the path-tracing tutorial.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)).

```{image} images/time_gated_restir_offline.png
:alt: Time-gated Cornell box rendered with TG ReSTIR
:width: 360px
:align: center
```

## 1. Load the scene

```{literalinclude} code/time_gated_restir_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The graph is the same as for the path tracer; only the tracer changes. `TimeGatedReSTIRInline`
takes the path tracer's options for its initial candidates (here 16 per pixel) and the gate, plus
the reuse options:

- `spatialReuseIteration`, `spatialReuseNeighborCount`, `spatialReuseGatherRadius`: 3 rounds of
  spatial reuse, each resampling 5 neighbors within 10 pixels.
- `useTemporalReuse`: off. Temporal reuse also reuses paths from earlier frames, which is meant
  for online rendering; here every frame is independent and `AccumulatePass` averages them.
- `shiftmapMethod`, `gaugeMode`, `specularRoughnessThreshold`: how a neighbor's path is shifted to
  this pixel while keeping its length. The defaults do not shift paths (`no`), so set them.

```{literalinclude} code/time_gated_restir_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

A ReSTIR frame costs more than a path-tracing frame with the same number of initial samples, but
each of its pixels gathers many more paths that fit the gate.

```{literalinclude} code/time_gated_restir_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Save the image"
```

## 4. Save the image

```{literalinclude} code/time_gated_restir_offline.py
:language: python
:start-after: "# 4. Save the image"
```

The full script: {download}`time_gated_restir_offline.py <code/time_gated_restir_offline.py>`.

## Equal-time comparison

To compare the two tracers fairly, give each the same rendering time. The comparison script
builds the same render graph around `TimeGatedPathTracerInline` and `TimeGatedReSTIRInline` (16
initial samples per pixel each, same gate), renders each for 1 second, and compares both with a
reference rendered by the path tracer with 65,536 samples per pixel. The error is the relative
mean squared error, $\mathrm{relMSE} = \overline{(I - I_\mathrm{ref})^2} / \overline{I_\mathrm{ref}^2}$.

The timing waits for the GPU after every frame, so it measures the full cost of each frame, and
leaves out a few warm-up frames, in which the shaders are compiled:

```{literalinclude} code/time_gated_equal_time.py
:language: python
:start-after: "# 3. Render each tracer for the same time"
:end-before: "# 4. Render a reference"
```

```{image} images/time_gated_equal_time.jpg
:alt: Equal-time comparison of TGPT and TG ReSTIR with a reference
:align: center
```

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - Method (1 second)
  - Frames
  - Samples per pixel
  - relMSE
* - `TimeGatedPathTracerInline`
  - 206
  - 3,296
  - 0.0858
* - `TimeGatedReSTIRInline`
  - 112
  - 1,792 initial
  - 0.0120
```

In the same time, ReSTIR renders about half as many frames but reaches a 7 times lower error.
These numbers were measured on an NVIDIA GeForce RTX 3090 with Vulkan; frame counts and errors
depend on the GPU.

The full comparison script, which also saves the image above:
{download}`time_gated_equal_time.py <code/time_gated_equal_time.py>`. It takes about 40 seconds,
most of it for the reference.
