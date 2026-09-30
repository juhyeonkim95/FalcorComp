# Transient ReSTIR (offline)

This tutorial renders the transient histogram of the Cornell box from
[Transient rendering (offline)](transient_offline.md) with `TransientHistogramReSTIRInline`
instead of the path tracer, and then compares the two at equal rendering time.

`TransientHistogramReSTIRInline` keeps one *reservoir* per pixel and bin: a single path whose
length falls in that bin. After sampling paths as the path tracer does, every bin of every pixel
reuses the paths its neighbors found in the same bin, shifted to this pixel with a
path-length-aware shift mapping that keeps their length inside the bin. The image below shows 16
of the 64 bins, in reading order.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)).

```{image} images/transient_restir_offline.jpg
:alt: 16 bins of the Cornell box's transient histogram, rendered with TH ReSTIR
:width: 512px
:align: center
```

## 1. Load the scene

```{literalinclude} code/transient_restir_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The graph is the same as for the path tracer; only the tracer changes. `TransientHistogramReSTIRInline`
takes the path tracer's options for its initial candidates (here 16 per pixel) and the histogram,
plus the reuse options:

- `spatialReuseIteration`, `spatialReuseNeighborCount`, `spatialReuseGatherRadius`: 3 rounds of
  spatial reuse, each resampling 5 neighbors within 10 pixels, in every bin.
- `useTemporalReuse`: off, so that every frame is independent and
  `TransientHistogramAccumulatePass` averages them. The comparison below also tries it on.
- `shiftmapMethod`, `gaugeMode`, `reconnectionRoughnessThreshold`: how a neighbor's path is
  shifted to this pixel while keeping its length. The defaults do not shift paths (`no`), so set
  them.

```{literalinclude} code/transient_restir_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

Every bin has its own reservoir, so a frame costs much more than a path-tracing frame with the
same number of initial samples: 256 frames take about 15 seconds on an RTX 3090.

```{literalinclude} code/transient_restir_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Read the histogram"
```

## 4. Read the histogram

As for the path tracer, `to_numpy()` returns the averaged histogram as bins x height x width x
RGBA, in radiance per unit path length.

```{literalinclude} code/transient_restir_offline.py
:language: python
:start-after: "# 4. Read the histogram"
:end-before: "# 5. Show 16 bins in a 4 x 4 grid"
```

## 5. Show 16 bins in a 4 x 4 grid

```{literalinclude} code/transient_restir_offline.py
:language: python
:start-after: "# 5. Show 16 bins in a 4 x 4 grid"
```

The full script: {download}`transient_restir_offline.py <code/transient_restir_offline.py>`.

(transient-equal-time)=
## Equal-time comparison

The comparison script builds the same render graph around `TransientHistogramPathTracerInline`
and `TransientHistogramReSTIRInline`, renders each for 1 second, and compares them with a
reference rendered by the path tracer with 65,536 samples per pixel. It tries ReSTIR twice: with
three rounds of spatial reuse as above, and with temporal reuse plus one spatial round, where
every frame also resamples the previous frame's reservoirs. The errors are taken over all bins:
the relative mean squared error,
$\mathrm{relMSE} = \overline{(H - H_\mathrm{ref})^2} / \overline{H_\mathrm{ref}^2}$, and the mean
absolute percentage error,
$\mathrm{MAPE} = \overline{|H - H_\mathrm{ref}| / (0.01\,\overline{H_\mathrm{ref}} + H_\mathrm{ref})}$,
which weighs dim texels as much as bright ones.

As in the time-gated comparison, the timing waits for the GPU after every frame and leaves out
a few warm-up frames:

```{literalinclude} code/transient_equal_time.py
:language: python
:start-after: "# 3. Render each tracer for the same time"
:end-before: "# 4. Render a reference"
```

```{image} images/transient_equal_time.jpg
:alt: Four bins of the histogram from THPT, TH ReSTIR with and without temporal reuse, and a reference
:align: center
```

```{list-table}
:header-rows: 1
:widths: 40 12 18 15 15

* - Method (1 second)
  - Frames
  - Samples per pixel
  - relMSE
  - MAPE
* - `TransientHistogramPathTracerInline`
  - 455
  - 7,280
  - 0.0365
  - 0.185
* - `TransientHistogramReSTIRInline`, spatial x 3
  - 16
  - 256 initial
  - 0.0684
  - 0.236
* - `TransientHistogramReSTIRInline`, temporal + spatial x 1
  - 28
  - 448 initial
  - 0.0642
  - 0.176
```

Unlike a narrow time gate, a histogram gives the path tracer an easy task: every path it traces
lands in some bin, so none of its work is wasted, while ReSTIR does its reuse separately for each
of the 64 bins. In this scene the path tracer therefore reaches a lower relMSE in the same time.
With temporal reuse, ReSTIR's MAPE is slightly lower, but its relMSE stays higher; its noise is
smoother, but correlated between neighboring pixels. ReSTIR pays off where
paths that reach the laser spot are hard to find, such as scenes lit indirectly, and in online
rendering, where every frame is shown on its own
(see [Transient ReSTIR (online)](transient_restir_online.md)).

These numbers were measured on an NVIDIA GeForce RTX 3090 with Vulkan; frame counts and errors
depend on the GPU.

The full comparison script, which also saves the image above:
{download}`transient_equal_time.py <code/transient_equal_time.py>`. It takes about 30 seconds,
most of it for the reference.
