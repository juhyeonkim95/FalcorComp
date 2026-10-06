# Frame difference (`EventDifference`)

This render pass computes the change of a rendered image between consecutive frames at each pixel, for event
cameras. It keeps the previous frame's render and outputs $\Delta I$, $\Delta L$ and the image; see
[Event camera rendering](../event.md).

- `sampling = independent`: one render per frame (`color1`), $\Delta I_t = I_t - I_{t-1}$. Each frame's render has
  new random numbers, so its noise is in the difference.
- `sampling = correlated`: two renders per frame, `color1` with the previous frame's seed and `color2` with the
  current one; $\Delta I_t = I^1_t - I^2_{t-1}$, the pair with the same seed (see
  [Correlated sampling](#event-correlated-sampling)). The image is $(I^1_t + I^2_t) / 2$.

$\Delta L_t = \log(I_\epsilon + \ell_t) - \log(I_\epsilon + \ell_{t-1})$ for the luminance $\ell$ of the same two
renders.

## Event frames of several renders

`PathTracer` renders at most 16 samples per pixel. With `subframes` $= N$, the pass averages $N$ executions into
one event frame; the script holds the scene still and gives each execution new seeds, keeping the pairing: in
execution $k$ of frame $t$, `color1` uses seed $(t-1)N + k$ and `color2` seed $tN + k$. The outputs keep the last
complete event frame in between, and the [`EventGenerator`](EventGenerator.md) fed by `deltaL` fires only when a
frame completes. This gives references with thousands of samples per pixel.

A pixel with a non-finite sample (NaN or infinity) in an event frame gets no difference for it, and its history keeps
the last finite frame.

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `sampling`
  - string
  - `independent` or `correlated`. (Default: `correlated`)
* - `intensityBias`
  - float
  - $I_\epsilon$ in $L = \log(I_\epsilon + I)$. (Default: `1e-8`)
* - `subframes`
  - integer
  - Executions averaged into one event frame. (Default: `1`)
```

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `color1` (input)
  - The frame's render; `correlated`: with the previous frame's seed.
* - `color2` (input, optional)
  - `correlated`: the frame's render with the current seed.
* - `deltaI`, `deltaL`, `primal` (outputs)
  - See [Outputs](#event-outputs).
```

From Python: `reset()` forgets the previous frame; `subframe` and `event_frame` give the position in the current
event frame and the number of completed event frames.

## Example

```python
graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
for tracer in ["TracerA", "TracerB"]:
    graph.create_pass(tracer, "PathTracer", {"samplesPerPixel": 1, "fixedSeed": 0})
    graph.add_edge("GBuffer.vbuffer", f"{tracer}.vbuffer")
graph.create_pass("Difference", "EventDifference", {"sampling": "correlated"})
graph.add_edge("TracerA.color", "Difference.color1")
graph.add_edge("TracerB.color", "Difference.color2")
graph.mark_output("Difference.deltaL")

for frame in range(frames):
    # ... move the camera ...
    graph.get_pass("TracerA").fixedSeed = frame
    graph.get_pass("TracerB").fixedSeed = frame + 1
    testbed.frame()
```

The [event camera tutorial](../../tutorials/event_camera_offline.md) is a complete script.
