# Transient histogram accumulation (`TransientHistogramAccumulatePass`)

This render pass averages a transient histogram over frames, as Falcor's `AccumulatePass` does for images. Its
input is one frame's histogram of `width x height x timeBin` texels, from
[`TransientHistogramPathTracerInline`](TransientHistogramPathTracerInline.md) or
[`TransientHistogramReSTIRInline`](TransientHistogramReSTIRInline.md). Its output has the input's size and format and
holds the mean of the frames since the average last restarted, in the input's unit (radiance per unit path length).
The pass keeps a running mean,

$$
\bar{H}_n = \bar{H}_{n-1} + \frac{H_n - \bar{H}_{n-1}}{n},
$$

where $H_n$ is the histogram of the $n$-th frame, so the output is a mean after every frame and needs no division.
All four channels are averaged, alpha included.

The input must be a single frame's histogram. With the path tracer's `accumulate`, its histogram is already a sum
over frames, and this pass does not divide it by their number: leave `accumulate` off when you use this pass. For the
path tracer, `accumulate` is the cheaper way to combine frames (see [Memory](#th-accumulate-memory));
`TransientHistogramReSTIRInline` has no `accumulate`, so its frames are averaged with this pass.

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `enabled`
  - boolean
  - Average the frames. Off, the output is a copy of the input, and the average starts anew when it is turned back
    on. (Default: `true`)
* - `autoReset`
  - boolean
  - Restart the average when the camera, the scene or the settings of an earlier pass change; see
    [When the average restarts](#th-accumulate-restart). Off, the average goes on through such changes and mixes
    the frames from before and after them. (Default: `true`)
* - `precisionMode`
  - string
  - How the running mean is kept: `Single`, in 32-bit floats, or `SingleCompensated`, the same with Kahan summation
    of the increments, for long runs, at the cost of one more texture of the input's size. (Default: `Single`)
* - `maxFrameCount`
  - integer
  - Stop averaging after this many frames: the output keeps the last average, and later frames are ignored until
    the average restarts. `0`: no limit. (Default: `0`)
```

(th-accumulate-restart)=
## When the average restarts

With `autoReset`, the average restarts when:

- the camera moves or changes in another way, e.g. its field of view (camera jitter does not count),
- the scene changes in any other way, or
- a pass that runs before this one in the frame reports a change, as the tracers and `VBufferRT` do when one of
  their settings changes and `LaserLight` does when the laser moves or changes.

With or without `autoReset`, it also restarts when:

- `reset()` is called from Python, or *Reset* is pressed in the pass's panel,
- `enabled` or `precisionMode` changes,
- the input's size or format changes (e.g. with `timeBin`, `useSingleChannel` or the frame size), or
- a new scene is loaded.

Changing `autoReset` or `maxFrameCount` keeps the current average. The pass's panel in the Render Graph window shows
the number of averaged frames.

(th-accumulate-memory)=
## Memory

Besides its output, the pass keeps the running mean in a texture of the input's size, and with `SingleCompensated` a
second one for the compensation. A graph with this pass after a tracer thus holds three histograms (four with
`SingleCompensated`): the tracer's, the mean and the output. At 1024 x 1024 with 512 RGBA bins, that is 24 GB,
against 8 GB for the path tracer with `accumulate`.

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `input` (input)
  - One frame's transient histogram, `width x height x timeBin`, RGBA32Float or R32Float: the `histogram` output
    of a transient tracer.
* - `output` (output)
  - The mean of the input over the averaged frames, with the input's size and format. `to_numpy()` returns an array
    of shape `(timeBin, height, width, 4)`, or `(timeBin, height, width)` for an R32Float input.
```

The pass publishes the number of averaged frames to the render graph, and that its output is a mean, so a
`TransientHistogramViewer` downstream shows the frame count and does not divide by it. From Python, `reset()`
restarts the average, e.g. `graph.get_pass("Accumulate").reset()` after a few warm-up frames.

## Example

```python
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
graph = testbed.create_render_graph("Transient")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0], "laserPower": [170.0, 120.0, 40.0],
})
graph.create_pass("Tracer", "TransientHistogramPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeMin": 16.75, "timeMax": 18.03, "timeBin": 64,
})
graph.create_pass("Accumulate", "TransientHistogramAccumulatePass", {})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser", "Tracer")  # run the laser pass first
graph.add_edge("Tracer.histogram", "Accumulate.input")
graph.mark_output("Accumulate.output")
testbed.render_graph = graph

for _ in range(256):
    testbed.frame()
histogram = graph.get_output("Accumulate.output").to_numpy()  # the mean of 256 frames, (64, height, width, 4)
```

See the [transient rendering tutorial](../../tutorials/transient_offline.md) for a complete script, and the
[transient ReSTIR tutorial](../../tutorials/transient_restir_offline.md) for this pass after
`TransientHistogramReSTIRInline`.
