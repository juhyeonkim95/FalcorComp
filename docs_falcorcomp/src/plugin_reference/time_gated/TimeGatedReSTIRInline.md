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
  - Gate kernel: `box`, `tent`, `cos` or `all` (no gating). (Default: `box`)
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
  - Candidate paths per pixel in each frame. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a candidate path, counting the primary hit. The
    primary hit itself is not connected to the laser spot. (Default: `3`)
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
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending a candidate path. (Default: `true`)
* - `timeGateWindowRough`, `roughTimeGateSampleRatio`
  - float
  - Wide-gate sampling, see [Wide gate](#restir-wide-gate). `timeGateWindowRough` 0 turns it off.
    (Default: `0`, `0.5`)
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
* - `useTemporalReuse`
  - boolean
  - Resample the previous frame's reservoir, reprojected with motion vectors when the `mvec`
    input is connected. (Default: `false`)
* - `temporalHistoryLength`
  - float
  - Cap on the history's sample count, in frames of `samplesPerPixel`. 0 ignores the history; a
    negative value leaves it uncapped. (Default: `20`)
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
    fixed), `local_tangent`, `barycentric`, `ray_trace`, `area_adaptive` or `ray_trace_chart`.
    See [Shift mapping](#restir-shift-mapping). (Default: `no`)
* - `specularRoughnessThreshold`
  - float
  - A path can reconnect at a segment only if both of its vertices are rougher than this.
    (Default: `0.25`)
* - `gaugeMode`
  - string
  - The direction the Newton solve keeps fixed: `constant` (along `gaugeAxis`), `grad`
    (orthogonal to the path-length gradient at the start) or `avg_grad` (orthogonal to the
    average gradient). (Default: `constant`)
* - `gaugeAxis`
  - float pair
  - Chart-space axis for `constant`. `[0, 0]` picks a random axis for every shift.
    (Default: `[1, 0]`)
* - `NewtonMaxIteration`
  - integer
  - Maximum Newton iterations per shift. (Default: `5`)
* - `NewtonRelativeTolerance`
  - float
  - Accepted and stored, but currently has no effect. (Default: `0.01`)
```

Other:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
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

The path tracer's `computeDirect` is accepted but has no effect in this pass. The reservoirs
resample by the luminance of the path contribution, or by the channel kept with
`useSingleChannel`.

## Every frame

1. **Initial sampling.** Every pixel traces `samplesPerPixel` candidate paths from its primary
   hit, connects them to the laser spot as the path tracer does, and keeps one of them in its
   reservoir, chosen in proportion to its contribution through the gate.
2. **Temporal reuse** (with `useTemporalReuse`). The pixel resamples its reservoir from the
   previous frame, shifted to the current gate.
3. **Spatial reuse**, `spatialReuseIteration` rounds. The pixel resamples the reservoirs of
   `spatialReuseNeighborCount` random pixels within `spatialReuseGatherRadius`, each shifted to
   this pixel.
4. **Output.** The pixel's reservoir gives its estimate of the time-gated image.

Reuse gives a lower-variance image per frame, but not an independent one: neighboring pixels and
consecutive frames share paths. Averaging frames with `AccumulatePass` reduces the remaining
noise.

(restir-shift-mapping)=
## Shift mapping

Reusing a path at another pixel changes its first segments (a different primary hit, and possibly
a different gate), so its length changes too. The shift keeps the rest of the path and moves the
*reconnection vertex*, the first vertex where the path may reconnect (a segment whose two
vertices are both rougher than `specularRoughnessThreshold`), so that the shifted path has the
length it needs. The move is a Newton solve on a 2D chart around that vertex, chosen by
`shiftmapMethod`; the path-length constraint fixes only one direction, and `gaugeMode` fixes the
other. With `no`, the vertex is not moved, so the shifted path often no longer fits the gate.

`local_tangent` with `avg_grad` is a good starting point, and is what the tutorials use.

## Moving the gate

With `shiftGate`, the gate moves to the next center after every frame. Temporal reuse keeps its
history and shifts the previous frame's paths to the new gate. The move also flags the render
graph, which restarts downstream accumulation.

From a script, `set_time_gate_info(timeMin, timeMax, timeBin)` sets the gate range, and
`increment_time_gate_frame()` advances the gate index. Both keep the temporal history, and
neither restarts downstream accumulation; reset an `AccumulatePass` yourself if you use one.
Changing an option in the UI discards the history.

## When the history is discarded

The temporal history is discarded, and the next frame starts from its own samples only, when:

- an option changes in the UI,
- the scene changes in any way other than camera motion (without `isSceneDynamic`, a laser change
  counts too),
- the frame size changes, or
- the camera uses depth of field.

(restir-wide-gate)=
## Wide gate

With `direct` sampling and a `box` or `tent` gate, `timeGateWindowRough` wider than
`timeGateWindow` traces a fraction `roughTimeGateSampleRatio` of the candidate paths against the
wider gate, and shrinks them into the gate with the path-length shift. This finds candidates for
very narrow gates that direct sampling rarely hits. 0 turns it off.

(restir-connection-sampling)=
## Connection sampling

As for the [path tracer](TimeGatedPathTracerInline.md): `direct` connects every vertex to the
laser spot, `ellipsoidal` inserts a vertex whose length fits the gate, and `ellipsoidal_direct_mis`
combines both. With `isSceneDynamic`, ellipsoidal sampling supports at most 3 bounces.

## Laser

The laser is set on `LaserVBufferRT`, as for the [path tracer](#laser).

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
* - `laservbuffer` (input, optional)
  - Laser hit, from `LaserVBufferRT`.
* - `laserviewW` (input, optional)
  - Laser ray direction, from `LaserVBufferRT`.
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
    "specularRoughnessThreshold": 0.05,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
graph.add_edge("Laser.viewW", "Tracer.laserviewW")
```

See the [offline](../../tutorials/time_gated_restir_offline.md) and
[online](../../tutorials/time_gated_restir_online.md) ReSTIR tutorials for complete scripts.
