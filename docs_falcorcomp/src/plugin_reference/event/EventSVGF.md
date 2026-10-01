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
   $\Delta i_t = i^1_t - i^2_{t-1}$.
2. **Temporal accumulation.** The primal is blended with the previous frame's result at the position given by the
   motion vectors, as in SVGF. The difference is blended with the previous difference there, plus the correction
   $I'_{t-2}[s + \Delta_t s] - I'_{t-2}[s + \Delta_{t-1} s]$, which turns the moved difference back into the change
   at the fixed pixel $s$ (Eq. 15-16 of the paper). The accumulation restarts where the pixel shows a different
   surface than in the previous frame.
3. **Spatial filtering.** An à-trous wavelet filter with edge-stopping weights on depth, normal and luminance. The
   difference's weight is the primal's times a second weight (difference-aware weight, Eq. 12): on the previous
   frame's depth and normal, and on the difference's luminance, scaled by the difference's own variance. Emitters are
   left out of the difference's filter.
4. **Remodulation.** $\Delta I_t = A_t \Delta i_t + (A_t - A_{t-1}) i_{t-1} + (E_t - E_{t-1})$ and
   $\Delta L_t = \log(I_\epsilon + I_{t-1} + \Delta I_t) - \log(I_\epsilon + I_{t-1})$, with the denoised
   $I_{t-1} = A_{t-1} i_{t-1} + E_{t-1}$. Where the pixel shows a different surface or an emitter in either frame,
   the difference of the denoised primals is used instead.

Everything is computed on the luminance.

## Parameters

```{list-table}
:header-rows: 1
:widths: 30 10 60

* - Parameter
  - Type
  - Description
* - `iterations`
  - integer
  - à-trous iterations; iteration $k$ has step $2^k$. (Default: `4`)
* - `feedbackTap`
  - integer
  - The iteration whose output is the next frame's history; `-1`: the unfiltered accumulation. (Default: `1`)
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
  - Divide by the albedo before filtering. (Default: `true`)
* - `useDifferenceAwareFiltering`
  - boolean
  - The difference's weights also need the previous frame's depth and normal to agree. (Default: `true`)
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

From Python: `reset()` forgets the history.

## Example

```python
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
```

Set the seeds of `TracerA` and `TracerB` every frame as in [Correlated sampling](#event-correlated-sampling). The
[event camera tutorial](../../tutorials/event_camera_offline.md) compares EventSVGF with path tracing.
