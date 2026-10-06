# Time-gated ReSTIR (`TimeGatedReSTIRInline`)

This render pass renders the same time-gated image as the
[time-gated path tracer](TimeGatedPathTracerInline.md), the radiance of the paths whose optical
length falls inside the gate, but with ReSTIR: every pixel samples candidate paths, keeps one in a
*reservoir*, and then resamples the reservoirs of neighboring pixels (spatial reuse) and of the
previous frame (temporal reuse). A reused path is moved to the new pixel and gate with a
*path-length-aware shift mapping*, which keeps its length inside the gate. This finds many more
paths that fit a narrow gate than path tracing does in the same time.

## Parameters

The time gate is set as for the path tracer:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `timeGateMode`
  - string
  - Gate kernel: `box`, `tent`, `gaussian`, `exp` (one-sided exponential), `exp_two_side`
    (two-sided exponential), `epanechnikov`, `perlin` or `all` (no gating). See
    [the kernels](#gate-kernels). `cos` is not available: its negative weights cannot be resampled.
    (Default: `box`)
* - `timeGateWindow`
  - float
  - Gate width $\Delta$, in path-length units. (Default: `0.05`)
* - `timeMin`, `timeMax`
  - float
  - Range of gate centers. Equal values give a single fixed gate. (Default: `9`, `12`)
* - `timeCenter`
  - float
  - Shortcut for a single fixed gate: sets `timeMin` and `timeMax` to this value. (Optional)
* - `timeBin`
  - integer
  - Number of gate centers from `timeMin` to `timeMax`. (Default: `512`)
* - `shiftGate`
  - boolean
  - Move the gate to the next center after every frame, wrapping from `timeMax` back to
    `timeMin`. The temporal history is kept and shifted to the new gate. (Default: `false`)
```

Initial sampling, the candidate paths each pixel starts from in every frame:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `samplesPerPixel`
  - integer
  - Camera paths traced per pixel in each frame; every connection to the laser spot along them is
    a candidate. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a candidate path, counting the primary hit and any
    vertex inserted by an ellipsoidal connection. The primary hit itself is not connected to the
    laser spot. (Default: `3`)
* - `samplingMethod`
  - string
  - How a candidate path's vertices are connected to the laser spot: `direct`, `ellipsoidal` or
    `ellipsoidal_direct_mis`, as for the path tracer (see
    [Connection sampling](#restir-connection-sampling)). (Default: `direct`)
* - `specularRoughnessThresholdEllipsoid`
  - float
  - With `ellipsoidal`, a vertex uses an ellipsoidal connection only if its roughness is above
    this value. (Default: `0.25`)
* - `emissiveSampler`
  - string
  - How an ellipsoidal connection picks the scene triangle to place its vertex on: `Uniform` or
    `LightBVH`. Unused with `direct`. (Default: `LightBVH`)
* - `ellipsoidMaxTriangleArea`
  - float
  - Triangles larger than this (world-space area) never hold an ellipsoidal vertex, e.g. an NLOS
    relay wall that would take most samples; paths through them come from BSDF sampling. Unused with
    `direct`. (Default: `10000`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending a candidate path. (Default: `true`)
* - `useShrinkMapping`
  - boolean
  - Shrink mapping: trace candidate paths with a wider gate and shrink them into the gate. See
    [Shrink mapping](#restir-wide-gate). (Default: `false`)
* - `timeGateWindowRough`
  - float
  - Width of the wider gate. 0 uses 10 x `timeGateWindow`. (Default: `0`)
* - `roughTimeGateSampleRatio`
  - float
  - Fraction of the camera paths traced with the wider gate, clamped to [0, 1]; the others use the
    gate itself. (Default: `1`)
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
  - Neighbor pixels resampled in each round. (Default: `5`)
* - `spatialReuseGatherRadius`
  - float
  - Radius, in pixels, within which the neighbors are chosen. (Default: `10`)
* - `spatialReuseTwoPass`
  - boolean
  - Run each spatial round as two passes (every candidate's shifts in its own thread, then the
    resampling), which is faster with a length-aware shift. `false` runs the single-pass kernel;
    the results are the same. The shift `no` and `debugNewtonIterations` always use the single
    pass. (Default: `true`)
* - `useTemporalReuse`
  - boolean
  - Resample the previous frame's reservoir, reprojected with motion vectors when the `mvec`
    input is connected. (Default: `false`)
* - `temporalHistoryLength`
  - float
  - Cap on the history's sample count, in frames of `samplesPerPixel`; 0 ignores the history.
    Must not be negative. (Default: `20`)
* - `isSceneDynamic`
  - boolean
  - Keep the temporal history when the laser moves or changes, re-evaluating the lighting of
    reused paths. Otherwise any laser change discards the history. (Default: `false`)
* - `randomSeed`
  - integer
  - Seed of the random numbers in spatial reuse; it advances with every round. (Default: `0`)
```

Shift mapping:

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
    `radial`. See [Shift mapping](#restir-shift-mapping). (Default: `no`)
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
  - Maximum Newton iterations per shift. `radial` does not use it. (Default: `5`)
* - `NewtonRelativeTolerance`
  - float
  - Tolerance of the shift solve on the path length, relative to the path-length change of the shift. Looser
    solves leave the forward and reverse shifts slightly inconsistent, which biases reuse. (Default: `0.0002`)
* - `rayChartMaxDisplacement`
  - float
  - `ray_trace`, `ray_trace_chart` and `area_adaptive` only: rejects shifts that move the vertex farther than this in
    chart coordinates. Large moves can make the reverse shift converge to a different vertex, which biases reuse.
    Small caps (`0.01` for `ray_trace`, `0.02`-`0.05` for `ray_trace_chart`) remove that bias but reject many shifts,
    which raises the variance. `0` disables. (Default: `0`)
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
  - Include the shortest path, camera -> primary hit -> laser spot. It is evaluated at the primary
    hit without reuse and added to the output after reuse; see [Every frame](#restir-every-frame).
    (Default: `false`)
* - `useSingleChannel`
  - boolean
  - Keep one channel of the image, chosen by `singleChannel`: the reservoirs resample by that
    channel only, and it is written to all three color channels. (Default: `false`)
* - `singleChannel`
  - string
  - The channel kept by `useSingleChannel`: `luminance`, `red`, `green` or `blue`.
    (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing rays. (Default: `false`)
* - `debugNewtonIterations`
  - boolean
  - Add the `newtonStatistics` and `mappingDistance` outputs, which count the Newton solves of
    spatial reuse. (Default: `false`)
```

The reservoirs resample by the luminance of the path contribution, or by the channel kept with
`useSingleChannel`.

(restir-every-frame)=
## Every frame

1. **Initial sampling.** Every pixel traces `samplesPerPixel` paths from its primary hit,
   connects their vertices to the laser spot as the path tracer does, and keeps one of these
   candidates in its reservoir, chosen in proportion to its contribution through the gate.
2. **Temporal reuse** (with `useTemporalReuse`). The pixel resamples its reservoir from the
   previous frame, shifted to the current gate.
3. **Spatial reuse**, `spatialReuseIteration` rounds. The pixel resamples the reservoirs of
   `spatialReuseNeighborCount` random pixels within `spatialReuseGatherRadius`, each shifted to
   this pixel. Neighbors without a primary hit, or whose primary hit differs too much in normal or
   depth, are skipped.
4. **Output.** The pixel's reservoir gives its estimate of the time-gated image.
5. **Primary-hit direct** (with `computeDirect`). The path camera -> primary hit -> laser spot is
   evaluated in step 1 on its own, kept out of the reservoirs, and added to the output after the last
   reuse step. Its length is fixed for each pixel, so reuse would not help it.

Reuse gives a lower-variance image per frame, but not an independent one: neighboring pixels and
consecutive frames share paths. Averaging frames with `AccumulatePass` reduces the remaining
noise.

(restir-shift-mapping)=
## Shift mapping

Reusing a path at another pixel changes its first segments (a different primary hit, and possibly
a different gate), so its length changes too. The shift keeps the rest of the path and moves the
*reconnection vertex*, the first vertex where the path may reconnect (a segment whose two
vertices are both rougher than `reconnectionRoughnessThreshold` and that is longer than
`reconnectionMinDistance`), so that the shifted path has the length it needs. The move is a Newton
solve on a 2D chart around that vertex, chosen by `shiftmapMethod`; the path-length constraint
fixes only one direction, and `gaugeMode` fixes the other. `radial` instead moves the vertex along
the ray, in the vertex's plane, from the point where the path length is shortest (a 1D search), so
it needs no gauge. With `no`, the vertex is not moved, so the shifted path often no longer fits
the gate.

`local_tangent` with `avg_grad` is a good starting point, and is what the tutorials use.

## Moving the gate

With `shiftGate` and `timeMax` above `timeMin`, the gate moves to the next center after every
frame. Temporal reuse keeps its history and shifts the previous frame's paths to the new gate. The
move also flags the render graph, which restarts downstream accumulation.

From a script, `set_time_gate_info(timeMin, timeMax, timeBin)` sets the gate range, and
`increment_time_gate_frame()` advances the gate index. Both keep the temporal history, and
neither restarts downstream accumulation; reset an `AccumulatePass` yourself if you use one.
Changing an option in the UI or with `set_properties()` discards the history.

## When the history is discarded

The temporal history is discarded, and the next frame starts from its own samples only, when:

- an option changes in the UI or with `set_properties()`,
- the scene changes in any way other than camera motion (without `isSceneDynamic`, a laser change
  counts too),
- the frame size changes, or
- the camera uses depth of field.

## Limitations

- Static scene geometry: the camera may move (and, with `isSceneDynamic`, the laser), but objects may not move or
  deform; the history is discarded when geometry changes, as above.
- Layered materials (for example pbrt's `coateddiffuse` and `coatedconductor`) are not supported.

(restir-wide-gate)=
## Shrink mapping

With `useShrinkMapping`, `direct` sampling and a `box` or `tent` gate, a fraction
`roughTimeGateSampleRatio` of the candidate paths is traced against a wider gate,
`timeGateWindowRough` (10 x `timeGateWindow` unless set), and shrunk into the gate with the
path-length shift. This finds candidates for very narrow gates that direct sampling rarely hits.
It has no effect when the wider gate is not wider than `timeGateWindow`, or when
`roughTimeGateSampleRatio` x `samplesPerPixel` is below 1.

With a fraction of 1, every candidate uses the wider gate, and paths whose shift fails are lost:
in a test on the Cornell box (0.01 gate), the image was about 7 % darker than the reference. A
fraction below 1 keeps some candidates on the gate itself; with 0.5 and a 5 x wider gate the
difference was under 1 %.

(restir-connection-sampling)=
## Connection sampling

As for the [path tracer](TimeGatedPathTracerInline.md): `direct` connects every vertex to the
laser spot, `ellipsoidal` inserts a vertex whose length fits the gate, and `ellipsoidal_direct_mis`
combines both. With `isSceneDynamic`, ellipsoidal sampling supports at most 3 bounces.

## Laser

The laser is set on the `LaserLight` pass, as for the [path tracer](#laser).

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `vbuffer` (input)
  - Primary hits, from `VBufferRT`.
* - `viewW` (input, optional)
  - Primary ray directions, from `VBufferRT`. Needed for depth of field.
* - `mvec` (input, optional)
  - Motion vectors, from `VBufferRT`, to reproject the temporal history when the camera moves.
* - `color` (output)
  - Time-gated image, RGBA32Float.
* - `newtonStatistics` (output, with `debugNewtonIterations`)
  - Per pixel: mapping successes, successes after visibility, attempts, and the sum of Newton
    iterations, RGBA32Uint.
* - `mappingDistance` (output, with `debugNewtonIterations`)
  - Per pixel: summed chart-space and world-space displacement of successful shifts, RG32Float.
```

## Example

```python
graph.create_pass("Tracer", "TimeGatedReSTIRInline", {
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeGateMode": "box", "timeGateWindow": 0.02, "timeCenter": 17.337,
    "spatialReuseIteration": 3, "spatialReuseNeighborCount": 5,
    "shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad",
    "reconnectionRoughnessThreshold": 0.05,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser", "Tracer")  # run the laser pass first
```

See the [offline](../../tutorials/time_gated_restir_offline.md) and
[online](../../tutorials/time_gated_restir_online.md) ReSTIR tutorials for complete scripts.
