# Continuous-wave ToF path tracer (`CWToFPathTracerInline`)

This render pass renders a *continuous-wave time-of-flight* (CW-ToF) measurement. A CW-ToF camera
modulates its light source periodically and correlates the returning light with a reference signal,
so a light path contributes according to the phase of its optical length $\ell(\bar{\mathbf{x}})$ within the
modulation period. Each pixel estimates

$$
I = \int f(\bar{\mathbf{x}})\, m\!\left(\ell(\bar{\mathbf{x}})\right) \mathrm{d}\bar{\mathbf{x}}, \qquad
m(\ell) = w\!\left(\frac{\ell}{\lambda} - \phi\right),
$$

where $f$ is the path contribution, $\lambda$ the modulation wavelength (`modulationWavelength`, the
path length of one period), $\phi$ the sensor phase offset in periods (`phase`) and $w$ a periodic
waveform with zero mean (`waveform`):

```{list-table}
:header-rows: 1
:widths: 20 80

* - `waveform`
  - $w(t)$, with $s = t - \lfloor t \rfloor$ the position in the period
* - `cos`
  - $\cos(2\pi s)$
* - `triangle`
  - $1 - 4\,|c|$, with $c = s$ for $s < 1/2$ and $c = s - 1$ otherwise
* - `box`
  - $+1$ for $|c| < 1/4$, $-1$ otherwise
* - `sawtooth`
  - $2s - 1$
```

`cos`, `triangle` and `box` peak at $s = 0$. With `unsignedModulation`, the weight is
$0.5\,w + 0.5$, in $[0, 1]$, instead of $w$, in $[-1, 1]$. The zero-mean weight is the part that
antithetic sampling targets: the constant part of the unsigned weight is an ordinary, unmodulated
image. The output is the estimate itself; it is not divided by anything.

Camera paths start at the primary hits from `VBufferRT`, and every vertex is connected to the light
set on `LaserLight`. Paths are not cut off by length, because the modulation covers all path
lengths.

## Parameters

Modulation:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `modulationWavelength`
  - float
  - Modulation wavelength $\lambda$: the optical path length of one period, in scene units. Must be
    greater than zero. (Default: `1`)
* - `phase`
  - float
  - Sensor phase offset $\phi$, in periods (`0.25` is 90 degrees). (Default: `0`)
* - `waveform`
  - string
  - Modulation waveform: `cos`, `triangle`, `box` or `sawtooth`. (Default: `cos`)
* - `unsignedModulation`
  - boolean
  - Weight paths by $0.5\,w + 0.5$ instead of $w$. (Default: `false`)
```

Sampling:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `samplesPerPixel`
  - integer
  - Camera paths traced per pixel in each frame. Must be greater than zero. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a camera path, counting the primary hit. Each vertex is
    connected to the light. (Default: `3`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending the camera path; otherwise use the material's
    reference sampler (cosine-weighted for standard materials). (Default: `true`)
* - `useAntitheticSampling`
  - boolean
  - Pair every BSDF-sampled vertex with an antithetic vertex, whose path has the opposite
    modulation. See [Antithetic sampling](#cwtof-antithetic). (Default: `true`)
```

Antithetic shift mapping (used with `useAntitheticSampling`):

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `shiftMappingMethod`
  - string
  - How the antithetic vertex is found: `radial` (along the ray from the path length's minimum on the
    vertex's plane), or one of the Newton-based path-length-aware shift mappings: `local_tangent`,
    `barycentric`, `ray_trace`, `area_adaptive`, `ray_trace_chart`. `no` pairs the vertex with
    itself (no variance reduction). (Default: `radial`)
* - `gaugeMode`
  - string
  - Newton-based methods only: fixes the direction left free by the one path-length constraint.
    `constant`: the vertex moves orthogonally to the chart axis `gaugeAxis`; `grad`: along the
    path-length gradient at the start; `avg_grad`: along the average of the gradients at both ends.
    `grad` is not symmetric (the backward shift follows the gradient at the other end), so it biases
    the estimate. (Default: `avg_grad`)
* - `gaugeAxis`
  - float2
  - Chart axis of the `constant` gauge; `(0, 0)` picks a random axis per shift. (Default: `(1, 0)`)
* - `NewtonMaxIteration`
  - integer
  - Newton-based methods only: maximum Newton iterations per shift. (Default: `10`)
* - `NewtonRelativeTolerance`
  - float
  - Tolerance of the shift solve on the path length, relative to the path-length change of the shift,
    and at least the float32 resolution of the path lengths involved. Also used by `radial`. Looser
    solves make the antithetic shifts only approximately inverse. (Default: `1e-6`)
* - `rayChartMaxDisplacement`
  - float
  - `ray_trace`, `ray_trace_chart`, and `area_adaptive` on faces of area at most `0.01` (which it
    shifts with the ray chart) only: rejects shifts that move the vertex farther than this in chart
    coordinates, where the reverse shift may not return to the original vertex. `0` disables.
    (Default: `0`)
* - `antitheticRoundTripCheck`
  - boolean
  - Keep an antithetic vertex only if shifting it back returns to the starting vertex (within 1% of the shift
    distance). This makes the Newton-based methods unbiased, at the cost of a second shift;
    `radial` does not need it. (Default: `false`)
```

Output:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `computeDirect`
  - boolean
  - Include the shortest path, camera -> primary hit -> light. (Default: `true`)
* - `useSingleChannel`
  - boolean
  - Keep one channel of the image, chosen by `singleChannel`, and write it to all three color
    channels. (Default: `false`)
* - `singleChannel`
  - string
  - The channel kept by `useSingleChannel`: `luminance`, `red`, `green` or `blue`.
    (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing rays. (Default: `false`)
```

(cwtof-antithetic)=
## Antithetic sampling

With a short wavelength, the modulation changes sign many times across the paths a pixel samples,
so independent samples mostly cancel and the estimate is noisy. With `useAntitheticSampling`, every
BSDF-sampled vertex $y$ (after the primary hit) gets an antithetic vertex $y'$ on its surface such that the
path through $y'$ has the opposite modulation:

- `cos`, `triangle` and `box` satisfy $w(t + 1/2) = -w(t)$, so the antithetic path is half a
  wavelength longer or shorter, $\ell(y') = \ell(y) \pm \lambda/2$, with equal probability.
- `sawtooth` has no such shift; its antithetic point is the mirror image in the period, $t \to 1 - t$.

Because the two paths are geometrically close, their contributions are similar but their
modulations have opposite signs, so they largely cancel and the variance drops. The primal and
antithetic samples are combined with multiple importance sampling (balance heuristic). The two
shifts ($+\lambda/2$ and $-\lambda/2$, or the mirror with itself) are inverses of each other, so the
weights need the density of only these two points: no extra shift is evaluated. Where no antithetic
vertex exists (for example, it would leave the surface or be hidden from the previous vertex), the primal
sample is used alone, which keeps the estimate unbiased.

This needs the two shifts to be exact inverses of each other. The `radial` shift mapping guarantees
it: it moves the vertex along the ray from $m$, the point of the vertex's plane with the shortest
path length (found in closed form with the mirror construction), and the path length increases along
every such ray, so each target length has one solution on the ray, and the backward shift lands back
on the start. The Newton-based methods follow the average gradient, which can pick a different
solution near $m$ and leave a small bias; `antitheticRoundTripCheck` removes it. `radial` works on
planar faces: on finely tessellated curved surfaces, fewer vertices find an antithetic vertex on their
own plane, which reduces the variance reduction but not the correctness.

Antithetic sampling helps most when the wavelength is short compared with the scene (in the Cornell
box, below about 0.1 for path lengths around 17): with long wavelengths, the antithetic path is far from
the primal path and the two are no longer similar.

## Light

The light is set on the `LaserLight` pass, as for the time-gated passes (see [Laser](#laser)). A CW-ToF
camera is usually modeled with a point light at the camera: `isLightSourceLaser = false` and
`laserCollocated = true`.

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
* - `color` (output)
  - CW-ToF measurement $I$, RGBA32Float. With the signed weight it can be negative. Pixels with no
    primary hit are black: the environment map is not part of the measurement.
```

## Example

```python
graph.create_pass("Light", "LaserLight", {"isLightSourceLaser": False, "laserCollocated": True})
graph.create_pass("Tracer", "CWToFPathTracerInline", {
    "samplesPerPixel": 8, "maxBounces": 3, "computeDirect": False,
    "waveform": "cos", "modulationWavelength": 0.01,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")  # run the light pass first
```

See the [CW-ToF tutorial](../../tutorials/cwtof_offline.md) for a complete script.
