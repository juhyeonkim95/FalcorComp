# EventSVGF (`EventSVGF`)

This render pass denoises the frame difference from [correlated sampling](#event-correlated-sampling) for event
cameras (Kim et al., *Difference-aware Filtering for Event Camera Simulation*, EGSR 2026). Denoising each frame's
image and subtracting leaves the residual noise of both frames in the difference, which triggers false events.
EventSVGF instead filters the difference itself with an extension of SVGF (spatiotemporal variance-guided
filtering), at 1 + 1 samples per pixel per frame.

## How it works

Every frame:

1. **Demodulation.** Both renders are divided by the albedo of the primary hit, after subtracting its emission:
   $i = (I - E) / A$, so that textures are not blurred. The primal is $(i^1_t + i^2_t) / 2$ and the difference
   $\Delta i_t = i^1_t - i^2_{t-1}$. The albedo $A$ is the renderer's, e.g. `PathTracer.albedo`. A pbrt
   `coatedconductor` has none (zero), and dividing by the floor of 0.001 instead amplifies its noise: turn
   `useDemodulation` off for such scenes (see
   [Differences from Falcor](#differences-from-falcor)).
2. **Temporal accumulation.** The primal is blended with the previous frame's result at the position given by the
   motion vectors, as in SVGF. The difference is blended with the previous difference there, plus the correction
   $I'_{t-2}[s + \Delta_t s] - I'_{t-2}[s + \Delta_{t-1} s]$, which turns the moved difference back into the change
   at the fixed pixel $s$ (Eq. 15-16 of the paper). The accumulation restarts where the pixel shows a different
   surface than in the previous frame. A non-finite sample (NaN or infinity) is replaced by the history's value.
3. **Spatial filtering.** An à-trous wavelet filter with edge-stopping weights on depth, normal and luminance. The
   difference's weight is the primal's times a second weight (difference-aware weight, Eq. 12): on the previous
   frame's depth and normal, and on the difference's luminance, scaled by the difference's own variance. Emitters are
   left out of the difference's filter. Where the primal's or the difference's history is shorter than 4 frames
   (after a reset, a resize, a disocclusion, or every frame without temporal accumulation), the variance comes from a
   7 x 7 neighborhood instead of the history, as in SVGF, so that the filter works from the first frame; the value
   there is replaced by the neighborhood's weighted mean.
4. **Remodulation.** $\Delta I_t = A_t \Delta i_t + (A_t - A_{t-1}) i_{t-1} + (E_t - E_{t-1})$ and
   $\Delta L_t = \log(I_\epsilon + I_{t-1} + \Delta I_t) - \log(I_\epsilon + I_{t-1})$, with the denoised
   $I_{t-1} = A_{t-1} i_{t-1} + E_{t-1}$. Where the pixel shows a different surface or an emitter in either frame,
   the difference of the denoised primals is used instead; so is it where $I_{t-1} + \Delta I_t \le 0$, a denoised
   difference that would make the intensity negative (clamping it at 0 would give $\Delta L \approx \log I_\epsilon$,
   a burst of events that later frames do not take back).

Everything is computed on the luminance.

After a reset, the first frame outputs $\Delta I = \Delta L = 0$ and a filtered primal; the difference is filtered
spatially from the second frame on, and also accumulated over time from the fourth on where the pixel keeps its
surface. The variance comes from the history from the fourth frame on for the primal and from the sixth on for the
difference; history lengths are capped at 32 frames.

## Parameters

```{list-table}
:header-rows: 1
:widths: 30 10 60

* - Parameter
  - Type
  - Description
* - `iterations`
  - integer
  - à-trous iterations, 0 to 10; iteration $k$ has step $2^k$. With 0 there is no à-trous filter: the output is
    the accumulation, or its 7 x 7 mean where a history is short (step 3), and the accumulation is fed back as the
    history. (Default: `4`)
* - `feedbackTap`
  - integer
  - The iteration whose output is the next frame's history, at most the last one; `-1`: the
    unfiltered accumulation. (Default: `1`)
* - `phiColor`
  - float
  - Width of the luminance edge-stopping weight, in standard deviations. (Default: `10`)
* - `phiNormal`
  - float
  - Exponent of the normal edge-stopping weight. (Default: `128`)
* - `alpha`
  - float
  - Temporal blend factor of the primal and the difference (raised while the history is short). (Default: `0.1`)
* - `momentsAlpha`
  - float
  - Temporal blend factor of the moments, from which the variances come. (Default: `0.2`)
* - `intensityBias`
  - float
  - $I_\epsilon$ in $L = \log(I_\epsilon + I)$. (Default: `1e-8`)
* - `useDemodulation`
  - boolean
  - Subtract the emission and divide by the albedo before filtering (and undo both after). (Default: `true`)
* - `useDifferenceAwareFiltering`
  - boolean
  - The difference's à-trous weights also include the previous frame's depth and normal and the difference's
    luminance (Eq. 12); otherwise they are the primal's, and `useDifferenceVariance` has no effect. Emitters are left
    out either way. (Default: `true`)
* - `useTemporalAccumulation`
  - boolean
  - Accumulate the difference over time; otherwise only the primal. (Default: `true`)
* - `useDenoisedDifference`
  - boolean
  - $\Delta I$ from the denoised difference; otherwise from the difference of the denoised primals, as a primal
    denoiser would give. (Default: `true`)
* - `useDifferenceVariance`
  - boolean
  - The difference's luminance weight uses the difference's own variance; otherwise half the width of the primal's.
    (Default: `true`)
```

The last five switch off parts of the method for comparisons.

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `color1`, `color2` (inputs)
  - The frame rendered with the previous frame's seed and with the current one.
* - `albedo` (input)
  - Albedo of the primary hit, for example `PathTracer.albedo`.
* - `emission` (input)
  - Emission of the primary hit, `GBufferRT.emissive`.
* - `linearZ`, `normal`, `mvec` (inputs)
  - Linear depth and its slope, world-space normal and motion vectors: `GBufferRT.linearZ`, `GBufferRT.guideNormalW`
    and `GBufferRT.mvec`.
* - `deltaI`, `deltaL`, `primal` (outputs)
  - See [Outputs](#event-outputs); `deltaI` is the luminance in all three channels, `primal` is
    $A_\mathrm{rgb}\, i + E$.
* - `deltaIllumination` (output)
  - The denoised demodulated difference $\Delta i$, R32Float.
```

From Python: `reset()` forgets the history, as do a resize and a change of `iterations`, `feedbackTap`,
`intensityBias`, `useDemodulation`, `useTemporalAccumulation` or `useDenoisedDifference`.

## Example

```python
testbed.load_scene("cornell-box/scene-v4.pbrt")  # with its area light
graph = testbed.create_render_graph("Events")
graph.create_pass("GBuffer", "GBufferRT", {"samplePattern": "Center", "sampleCount": 1})
for tracer in ["TracerA", "TracerB"]:
    graph.create_pass(tracer, "PathTracer", {"samplesPerPixel": 1, "fixedSeed": 0})
    graph.add_edge("GBuffer.vbuffer", f"{tracer}.vbuffer")
graph.create_pass("Difference", "EventSVGF", {})
for source, target in {"TracerA.color": "color1", "TracerB.color": "color2", "TracerA.albedo": "albedo",
                       "GBuffer.emissive": "emission", "GBuffer.linearZ": "linearZ",
                       "GBuffer.guideNormalW": "normal", "GBuffer.mvec": "mvec"}.items():
    graph.add_edge(source, f"Difference.{target}")
graph.create_pass("Events", "EventGenerator", {"threshold": 0.2})
graph.add_edge("Difference.deltaL", "Events.deltaL")
graph.mark_output("Events.events")
testbed.render_graph = graph
```

Set the seeds of `TracerA` and `TracerB` every frame as in [Correlated sampling](#event-correlated-sampling). The
[event rendering with denoising tutorial](../../tutorials/event_denoising_offline.md) compares EventSVGF with path
tracing and primal denoisers.
