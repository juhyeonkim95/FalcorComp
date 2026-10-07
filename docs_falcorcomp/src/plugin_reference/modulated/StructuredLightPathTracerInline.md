# Structured light path tracer (`StructuredLightPathTracerInline`)

This render pass renders a *structured light* measurement: a projector shows a pattern on the scene,
and a light path contributes according to the pattern value at the projector coordinates through
which its last vertex is lit. Each pixel estimates

$$
I = \int f(\bar{\mathbf{x}})\, P\!\left(\xi(\bar{\mathbf{x}})\right) \mathrm{d}\bar{\mathbf{x}},
$$

where $f$ is the path contribution, $\xi \in [0, 1]^2$ the projector coordinates of the path's last
vertex (the one connected to the projector) and $P$ the pattern. Patterns are signed, in $[-1, 1]$,
with zero mean for the periodic and binary codes; with `unsignedModulation`, the projector shows
$0.5\,P + 0.5$, in $[0, 1]$, instead. The zero-mean part is the one that antithetic sampling
targets: the constant part of the unsigned pattern is an ordinary, uniformly lit image. The output is
the estimate itself; it is not divided by anything.

Camera paths start at the primary hits from `VBufferRT`, and every vertex is connected to the
projector.

## Projector

The projector is a pinhole with a rectangular field of view, after Mitsuba's projector emitter.
Its image coordinates $\xi = (u, v)$ run over $[0, 1]$ across the field of view: $u$ along the
projector's right and $v$ along its up. It emits $I_0\,P(\xi) / \cos^3\theta$ toward the point with
coordinates $\xi$, where $\theta$ is the angle to its axis and $I_0$ is `projectorIntensity`, so that
the image plane is lit uniformly.

By default the projector sits at the camera and looks along its view (`projectorCollocated`), which
lights what the camera sees but carries no depth information. Giving `projectorPosition`,
`projectorDirection` or `projectorUp` places it there instead, unless `projectorCollocated` is also
given.

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `projectorCollocated`
  - boolean
  - Place the projector at the camera, every frame: its position, view direction and up. (Default:
    `true`, or `false` when `projectorPosition`, `projectorDirection` or `projectorUp` is given)
* - `projectorPosition`
  - float3
  - Projector center, in world space, without `projectorCollocated`. (Default: `(0, 0, 0)`)
* - `projectorDirection`
  - float3
  - Viewing direction (normalized when used), without `projectorCollocated`. (Default: `(0, 0, -1)`)
* - `projectorUp`
  - float3
  - Up hint: $v$ runs along it, made orthogonal to the direction; without `projectorCollocated`.
    (Default: `(0, 1, 0)`)
* - `projectorFov`
  - float2
  - Full field of view along $u$ and $v$, in degrees. (Default: `(22.62, 22.62)`)
* - `projectorIntensity`
  - float3
  - Radiant intensity $I_0$ along the axis, per color channel. (Default: `(10, 10, 10)`)
```

## Patterns

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `pattern`
  - string
  - `constant`, `periodic`, `gray`, `xor`, `checkerboard` or `arbitrary` (see below).
    (Default: `periodic`)
* - `patternAxis`
  - string
  - Projector coordinate the 1D patterns vary along: `u` (vertical stripes) or `v` (horizontal
    stripes). (Default: `u`)
* - `invertPattern`
  - boolean
  - Negate the pattern. (Default: `false`)
* - `unsignedModulation`
  - boolean
  - Show $0.5\,P + 0.5$ instead of $P$. (Default: `false`)
* - `waveform`
  - string
  - `periodic`: `cos`, `triangle`, `box` or `sawtooth`, as defined for
    [CWToFPathTracerInline](CWToFPathTracerInline.md). (Default: `cos`)
* - `patternWavelength`
  - float
  - `periodic`: period, in projector coordinates (`0.01` gives 100 periods across the field of
    view). (Default: `0.05`)
* - `patternPhase`
  - float
  - `periodic`: offset, in periods. The pattern at coordinate $c$ along the axis is
    $w(c / \lambda - \phi)$, as for CW-ToF. (Default: `0`)
* - `patternBits`
  - integer
  - `gray`, `xor`: the pattern has $2^\text{bits}$ columns. (Default: `10`)
* - `patternBit`
  - integer
  - `gray`, `xor`: the bit shown, `0` for the finest stripes; below `patternBits`. (Default: `0`)
* - `patternBaseBit`
  - integer
  - `xor`: the base bit XORed with the higher bits (`0` for XOR-02, `1` for XOR-04, ...); below
    `patternBits`. (Default: `0`)
* - `checkerCells`
  - uint2
  - `checkerboard`: cells along $u$ and $v$. (Default: `(16, 16)`)
* - `checkerShift`
  - integer
  - `checkerboard`: sub-cell shift, `(shift mod 5, shift / 5)` fifths of a cell along $u$ and $v$,
    `0` to `24`. (Default: `0`)
```

The patterns and their antithetic maps (see [Antithetic sampling](#structured-light-antithetic)):

```{list-table}
:header-rows: 1
:widths: 20 45 35

* - `pattern`
  - $P(\xi)$
  - Antithetic map
* - `constant`
  - $1$ (uniform light).
  - None (the vertex itself).
* - `periodic`
  - The waveform along the axis.
  - Mirror image within the period.
* - `gray`
  - One bit of the Gray code of the column, $\pm 1$.
  - Swap the halves of each block of $2^{\text{bit}+1}$ columns.
* - `xor`
  - A Gray bit XORed with the base bit (Gupta et al. 2011); the Gray bit alone when `patternBit`
    is not above `patternBaseBit`.
  - Swap the halves of each block of $2^{\text{base}+1}$ columns.
* - `checkerboard`
  - Binary checkerboard.
  - One cell left, right, down or up, with equal probability, wrapping around.
* - `arbitrary`
  - A binary code set from Python, one value per column.
  - A column matching or interval mapping set with it.
```

An `arbitrary` pattern is set from Python on the pass:

```python
tracer = graph.create_pass("Tracer", "StructuredLightPathTracerInline", {"pattern": "arbitrary"})
tracer.set_pattern_data(values, antithetic_index=matching)
tracer.set_pattern_data(values, interval_ids=ids, intervals=intervals)
```

- `values`: `0` or `1` per column (along `patternAxis`), shown as $-1$ and $+1$; other values raise an
  error.
- `antithetic_index`: for each column, the column it is paired with, of the opposite value (for
  example the optimal-transport matching of the 0s and 1s). The pairing must be symmetric.
- `interval_ids` and `intervals`: for each column, the interval it belongs to, and for each interval
  `(srcStart, srcEnd, dstStart, dstEnd)`, in columns: the interval is mapped linearly onto another
  one, which must map back onto it.

Give the matching or the intervals (`interval_ids` and `intervals` together), or neither (no
antithetic map), not both. It raises an error when an entry is out of range: a partner or interval
id past the last column or interval, an interval with start >= end or past the last column, or a
column outside its interval's source range or not assigned to the interval whose source contains it
(the source ranges must partition the columns). It warns when the matching is not symmetric or does not pair opposite values, or when the intervals do
not map back onto themselves, which makes antithetic sampling biased or ineffective. Rendering with
`pattern = arbitrary` before `set_pattern_data` is called raises an error.

## Sampling

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
  - Maximum number of surface vertices on a camera path, counting the primary hit.
    `0` renders no light. (Default: `3`)
* - `samplingMethod`
  - string
  - How the vertex lit by the projector is reached from the camera path: `naive` (BSDF sampling,
    then a connection to the projector) or `antithetic` (the same, with each BSDF sample paired with
    its antithetic vertex; see [Antithetic sampling](#structured-light-antithetic)). (Default: `antithetic`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending the camera path; otherwise use the material's
    reference sampler (cosine-weighted for standard materials). (Default: `true`)
```

With either method, a vertex is lit by the projector only on the side its path arrived from: the projector never
lights a surface through it, so it does not light the inside of glass or other transmissive objects (they still
transmit the light that reflects off other surfaces).

(structured-light-antithetic)=
## Antithetic sampling

With a fine pattern, the pattern changes sign many times across the vertices a pixel's paths light,
so independent samples mostly cancel and the estimate is noisy. With `samplingMethod = antithetic`,
every BSDF-sampled vertex $y$ (after the primary hit, and not sampled from a delta lobe) gets an
antithetic vertex $y'$: the pattern's antithetic map sends $y$'s projector coordinates $\xi$ to $\xi'$, where
the pattern has the opposite sign, and $y'$ is where the projector ray through $\xi'$ hits the
scene. The two contributions are combined with multiple importance sampling (balance heuristic),
with the Jacobian

$$
\left|\frac{\mathrm{d}\omega'}{\mathrm{d}\omega}\right| =
\frac{\left|\mathrm{d}\omega' / \mathrm{d}\xi'\right|}{\left|\mathrm{d}\omega / \mathrm{d}\xi\right|}
\left|\frac{\mathrm{d}\xi'}{\mathrm{d}\xi}\right|,
\qquad
\left|\frac{\mathrm{d}\omega}{\mathrm{d}\xi}\right| \propto
\frac{\cos\theta_{y,x}}{\lVert x - y \rVert^2}\,
\frac{\lVert o - y \rVert^2}{\cos\theta_{y,o}}\, \cos^3\theta_o,
$$

where $\omega$ is the direction from the previous vertex $x$, $o$ the projector center, and
$\theta_{y,x}$, $\theta_{y,o}$ the angles at $y$ to $x$ and to $o$. $|\mathrm{d}\xi'/\mathrm{d}\xi|$
is 1 for every map but the interval mapping. The maps are their own inverses or come in inverse
pairs chosen with equal probability (the checkerboard's left/right and down/up), so the weights need
the density of only these two points: no extra map is evaluated. A pair is used only if both
vertices are lit by the projector and seen directly from $x$, which holds for both points of a pair
or for neither; otherwise the primal sample is used alone, which keeps the estimate unbiased.

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
  - Structured-light measurement $I$, RGBA32Float. With the signed pattern it can be negative.
    Pixels without a primary hit are black: the environment map is not part of the measurement.
```

The output options `computeDirect` (default `true` here), `useSingleChannel`, `singleChannel` and
`useAlphaTest` are the same as for [CWToFPathTracerInline](CWToFPathTracerInline.md).

## Example

```python
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
graph = testbed.create_render_graph("StructuredLight")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Tracer", "StructuredLightPathTracerInline", {
    "samplesPerPixel": 8, "maxBounces": 3, "computeDirect": False,
    "projectorPosition": [0.4, 1.0, 6.8], "projectorDirection": [0.0, 0.0, -1.0],
    "projectorFov": [30.0, 30.0],
    "pattern": "periodic", "waveform": "cos", "patternAxis": "u", "patternWavelength": 0.01,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.mark_output("Tracer.color")
testbed.render_graph = graph
```

See the [structured light tutorial](../../tutorials/structured_light_offline.md) for a complete
script.
