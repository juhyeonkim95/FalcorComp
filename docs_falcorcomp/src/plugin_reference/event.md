# Event camera rendering

An event camera reports, at each pixel, when the brightness $L = \log(I_\epsilon + I)$ changes by more than a
threshold $C$: a positive event when it rises, a negative one when it falls. Simulating one needs the brightness
change $\Delta L$ between frames at each fixed pixel (not motion-compensated), which is far smaller than the image
itself and so far more sensitive to Monte Carlo noise. These render passes compute $\Delta L$ from the renders of a
path tracer and turn it into events:

- [`EventDifference`](event/EventDifference.md): the frame difference of the renders, with independent or
  correlated sampling, and a reference by averaging many renders per frame.
- [`EventSVGF`](event/EventSVGF.md): the difference from correlated sampling, denoised with a difference-aware
  extension of SVGF (Kim et al., EGSR 2026).
- [`EventGenerator`](event/EventGenerator.md): events from $\Delta L$.

The renders come from Falcor's `PathTracer`, which supports every kind of light, with a `GBufferRT` that samples
the pixel centers (`"samplePattern": "Center"`).

(event-correlated-sampling)=
## Correlated sampling

Two frames rendered with independent random numbers differ by their noise, which buries $\Delta L$. Correlated
sampling renders each frame twice with `PathTracer`'s `fixedSeed`:

- `color1`: the current frame with the previous frame's seed $r_{t-1}$;
- `color2`: the current frame with the current seed $r_t$.

$\Delta I_t = I^1_t - I^2_{t-1}$ then compares two renders with the same random numbers, the previous frame's `color2`
being kept by the pass, so most of their noise cancels. The mean of the two renders is the frame's image. The script
sets the seeds before every frame:

```python
graph.get_pass("TracerA").fixedSeed = frame       # r_{t-1}: TracerA.color -> color1
graph.get_pass("TracerB").fixedSeed = frame + 1   # r_t:     TracerB.color -> color2
```

Create the tracers with a `fixedSeed` property (`{"fixedSeed": 0}`), which also turns on `PathTracer`'s
`useFixedSeed`: the Python attribute `fixedSeed` only changes the seed, and a tracer without `useFixedSeed` ignores it.

`PathTracer` gives sample $k$ of seed $s$ the random numbers of stream $s \cdot n + k$ ($n$ samples per pixel), so
different seeds never share random numbers. With the same seed, a pixel's path makes the same random decisions in
both frames; the paths differ where the scene moved, and sometimes a bounce reaches a different object, which leaves
a rare large difference.

(event-outputs)=
## Outputs

`EventDifference` and `EventSVGF` output the same channels, so either feeds `EventGenerator`:

```{list-table}
:header-rows: 1
:widths: 20 80

* - Channel
  - Description
* - `deltaI`
  - Intensity change $\Delta I_t$ of the frame, RGBA32Float (`EventSVGF`: luminance in all three channels).
* - `deltaL`
  - Brightness change $\Delta L_t = \log(I_\epsilon + I_t) - \log(I_\epsilon + I_{t-1})$ of the luminance,
    R32Float.
* - `primal`
  - The frame's image, RGBA32Float.
```

The first frame after a reset has no previous frame: its differences are 0. The passes do not reset by themselves
when the scene changes or the camera jumps to another view: call their `reset()` then, or the next difference
compares the two.

```{toctree}
:maxdepth: 1

event/EventDifference
event/EventSVGF
event/EventGenerator
```
