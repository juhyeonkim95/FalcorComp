# Transient histogram ReSTIR (`TransientHistogramReSTIRInline`)

This render pass renders the same transient histogram as the
[transient histogram path tracer](TransientHistogramPathTracerInline.md), the radiance per unit path
length in each of `timeBin` bins of `[timeMin, timeMax)`, but with ReSTIR. Every pixel keeps one
*reservoir* per bin: a single path whose length falls in that bin, chosen from the pixel's
candidate paths. The reservoirs are then resampled from neighboring pixels (spatial reuse), from
the previous frame (temporal reuse) and, optionally, from the adjacent bins of the same pixel. A
reused path is moved to the new pixel and bin with the *path-length-aware shift mapping* of
[time-gated ReSTIR](../time_gated/TimeGatedReSTIRInline.md), which keeps its length inside the bin.

The scene and the laser must be static; only the camera may move.

## Parameters

Histogram:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `timeMin`, `timeMax`
  - float
  - Path-length range of the histogram. Paths outside `[timeMin, timeMax)` are not recorded, except
    that the `tent` filter's first and last bins reach half a bin beyond it.
    (Default: `9`, `12`)
* - `timeBin`
  - integer
  - Number of bins. Every bin has its own reservoir, so the pass's memory and most of its work grow
    with this; see [Memory](#th-restir-memory). (Default: `64`)
* - `histogramFilter`
  - string
  - The bin filter: `box` (a path counts for the bin that contains its length) or `tent` (a path is
    split between the two bins whose centers are nearest to its length, as in
    [TransientHistogramPathTracerInline](TransientHistogramPathTracerInline.md)). (Default: `box`)
```

Kernel density estimation is not supported: `useKernelDensityEstimation` must be `false`
(`initialWindowRatio` has no effect).

Initial sampling, the candidate paths each pixel starts from in every frame:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `samplesPerPixel`
  - integer
  - Camera paths traced per pixel in each frame. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a camera path, counting the primary hit. Each vertex
    after the primary hit is connected to the laser spot, and the connection is a candidate for the
    bin its total length falls in. (Default: `3`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending a camera path. (Default: `true`)
```

Reuse:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `spatialReuseIteration`
  - integer
  - Rounds of spatial reuse per frame. 0 turns spatial reuse off. (Default: `1`)
* - `spatialReuseNeighborCount`
  - integer
  - Neighbor pixels resampled in each round, each at the same bin. (Default: `5`)
* - `spatialReuseGatherRadius`
  - float
  - Radius, in pixels, within which the neighbors are chosen. (Default: `10`)
* - `useBinReuse`
  - boolean
  - In each spatial round, also resample bins `i - 1` and `i + 1` of the same pixel, shifted by one
    bin width. (Default: `false`)
* - `useTemporalReuse`
  - boolean
  - Resample the previous frame's reservoirs, reprojected with motion vectors when the `mvec`
    input is connected. (Default: `false`)
* - `temporalHistoryLength`
  - float
  - Cap on the history's sample count, in frames of `samplesPerPixel`; 0 ignores the history.
    Must not be negative. (Default: `20`)
* - `randomSeed`
  - integer
  - Seed of the random numbers in spatial reuse; it advances with every round. (Default: `0`)
```

Shift mapping, as for [time-gated ReSTIR](#restir-shift-mapping):

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `shiftmapMethod`
  - string
  - The chart on which the reconnection vertex is moved: `no` (naive reuse: the vertex stays
    fixed), `local_tangent`, `barycentric`, `ray_trace`, `area_adaptive`, `ray_trace_chart` or
    `radial`. (Default: `no`)
* - `reconnectionRoughnessThreshold`
  - float
  - A path can reconnect at a segment only if both of its vertices are rougher than this.
    (Default: `0.25`)
* - `reconnectionMinDistance`
  - float
  - A path can reconnect at a segment only if it is longer than this, in scene units. Very short
    segments make the shift nearly singular. (Default: `0`)
* - `gaugeMode`
  - string
  - Fixes the direction the path-length constraint leaves free. `constant`: the vertex moves
    orthogonally to `gaugeAxis`; `grad`: along the path-length gradient at the start; `avg_grad`:
    along the average of the gradients at both ends. `radial` ignores it. (Default: `constant`)
* - `gaugeAxis`
  - float pair
  - Chart-space axis for `constant`. `[0, 0]` picks a random axis for every shift.
    (Default: `[1, 0]`)
* - `NewtonMaxIteration`
  - integer
  - Maximum Newton iterations per shift. (Default: `5`)
* - `NewtonRelativeTolerance`
  - float
  - Tolerance of the shift solve on the path length, relative to the path-length change of the
    shift. Looser solves bias reuse. (Default: `0.0002`)
* - `rayChartMaxDisplacement`
  - float
  - `ray_trace`, `ray_trace_chart`, and `area_adaptive` on faces it shifts with the ray chart, only:
    rejects shifts that move the vertex farther than this in chart coordinates, where the reverse
    shift may not return to the original vertex. `0` disables. (Default: `0`)
```

Performance. These options change how the work is split on the GPU, not the result:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `spatialReuseTwoPass`
  - boolean
  - Run each spatial round as two passes: every candidate's shifts at every bin in their own
    thread, then the resampling. Much faster with a length-aware shift. The shift `no` always uses
    the single pass. (Default: `true`)
* - `temporalReuseTwoPass`
  - boolean
  - Run temporal reuse as two passes after initial sampling (every bin's shifts in their own
    thread, then the merges) instead of inside it. Faster with a length-aware shift. The shift `no`
    always merges inside initial sampling. (Default: `true`)
* - `skipEmptyReservoirs`
  - boolean
  - Store only the reservoirs of bins that hold a path, plus every bin's weight and sample count in
    a small buffer. Faster while most bins are empty (initial sampling and the first spatial
    round); it gains little once temporal or repeated spatial reuse has filled the bins.
    (Default: `true`)
```

Other:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `computeDirect`
  - boolean
  - Include the shortest path, camera -> primary hit -> laser spot. Unlike in time-gated ReSTIR,
    it is a candidate in the reservoirs like any other path. (Default: `false`)
* - `useSingleChannel`
  - boolean
  - Keep one channel, chosen by `singleChannel`: the reservoirs resample by that channel only, the
    histogram stores only it (a quarter of the memory), and `color` holds it in all three channels.
    (Default: `false`)
* - `singleChannel`
  - string
  - The channel kept by `useSingleChannel`: `luminance`, `red`, `green` or `blue`.
    (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing rays. (Default: `false`)
```

Without `useSingleChannel`, the reservoirs resample by the luminance of the path contribution.

## Every frame

1. **Initial sampling.** Every pixel traces `samplesPerPixel` camera paths from its primary hit and
   connects their vertices to the laser spot. Each connection is a candidate for the bin that
   contains its total length, and each bin's reservoir keeps one of its candidates, chosen in
   proportion to its contribution. Most bins of a pixel receive no candidate and stay empty.
2. **Temporal reuse** (with `useTemporalReuse`). Every bin resamples the same bin of the previous
   frame's reservoirs at the reprojected pixel, shifted to the current camera.
3. **Spatial reuse**, `spatialReuseIteration` rounds. Every bin resamples the same bin of
   `spatialReuseNeighborCount` random pixels within `spatialReuseGatherRadius`, and with
   `useBinReuse` also the adjacent bins of its own pixel. Neighbors without a primary hit, or whose
   primary hit differs too much in normal or depth, are skipped.
4. **Output.** Each bin's reservoir gives its estimate of that bin of the histogram.

Spatial reuse fills empty bins quickly: in a test on the Cornell box with 16 paths per pixel,
about 10 % of the bins held a path after initial sampling, 34 % after one spatial round and 88 %
after three.

As with time-gated ReSTIR, reuse lowers the noise of each frame but makes neighboring pixels and
consecutive frames share paths.

## When the history is discarded

The temporal history is discarded, and the next frame starts from its own samples only, when:

- an option changes in the UI,
- the scene or the laser changes in any way other than camera motion, including a camera animated by
  the scene,
- the frame size changes, or
- the camera uses depth of field.

Per pixel, the history is reused only if it saw the same surface: the same material, an orientation
within about 45 degrees and a distance within 10 % (otherwise, e.g. where the camera's motion uncovers
a surface, the pixel starts from its own samples).

(th-restir-memory)=
## Memory

The pass keeps two sets of reservoirs, this frame's and the previous one's, each with `timeBin`
reservoirs of about 100 bytes per pixel: at 480 x 270 with 64 bins that is about 1.8 GB. The
two-pass reuse adds up to 512 MB of intermediate results, processing the bins in chunks when they
do not fit at once.

## Limitations

- Static scene geometry: the camera may move, but objects may not move or deform (the history is discarded when
  geometry changes, as above), and the laser is assumed static.
- Layered materials (for example pbrt's `coateddiffuse` and `coatedconductor`) are not supported.

## Laser

The laser is set on the `LaserLight` pass, as for the
[time-gated path tracer](#laser). Moving or changing it discards the temporal history.

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `vbuffer` (input)
  - Primary hits, from `VBufferRT`.
* - `viewW` (input, optional)
  - Primary ray directions, from `VBufferRT`.
* - `mvec` (input, optional)
  - Motion vectors, from `VBufferRT`, to reproject the temporal history when the camera moves.
* - `histogram` (output)
  - Transient histogram, `width x height x timeBin`. RGBA32Float, or R32Float with
    `useSingleChannel`.
* - `color` (output)
  - Radiance of the frame, summed over all bins, RGBA32Float.
```

The pass publishes the histogram's range to the render graph, so a `TransientHistogramViewer`
downstream labels the path lengths. From a script, `reset_histogram()` clears the histogram before
the next frame.

## Example

```python
graph.create_pass("Tracer", "TransientHistogramReSTIRInline", {
    "samplesPerPixel": 16, "maxBounces": 4,
    "timeMin": 16.75, "timeMax": 18.03, "timeBin": 64,
    "spatialReuseIteration": 1, "spatialReuseNeighborCount": 5,
    "useTemporalReuse": True,
    "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("VBuffer.mvec", "Tracer.mvec")
graph.add_edge("Laser", "Tracer")  # run the laser pass first
graph.mark_output("Tracer.histogram")
```

See the [offline](../../tutorials/transient_restir_offline.md) and
[online](../../tutorials/transient_restir_online.md) transient ReSTIR tutorials for complete scripts.
