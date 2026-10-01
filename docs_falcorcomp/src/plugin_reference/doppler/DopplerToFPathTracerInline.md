# Doppler ToF path tracer (`DopplerToFPathTracerInline`)

This render pass simulates a Doppler time-of-flight camera: a continuous-wave ToF camera whose light is modulated at
frequency $f_g$ and whose sensor is modulated at a slightly different frequency $f_g - \Delta f$. After the sensor's
low-pass filter, a path of optical length $\ell$ (meters) arriving at time $t$ is weighted by

$$
w(t, \ell) = \cos\!\left(2\pi\left(\Delta f\, t - \frac{f_g\, \ell}{c} - \phi\right)\right),
$$

and over the exposure $[0, T)$ the camera measures

$$
I = \frac{1}{T} \int_0^T \int f(\bar{\mathbf{x}}, t)\, w\big(t, \ell(\bar{\mathbf{x}}, t)\big)\, \mathrm{d}\bar{\mathbf{x}}\, \mathrm{d}t .
$$

When $T$ is a whole number of heterodyne periods $1/\Delta f$, light from static objects cancels, and what remains
comes from paths whose length changes during the exposure: the Doppler signal. Unlike
[`DopplerHistogramPathTracerInline`](DopplerHistogramPathTracerInline.md), the objects really move: every frame draws
a time $t$, moves the objects (see [Velocities](#doppler-velocities)) to their pose at $t$, and traces the paths
there.

(doppler-tof-antithetic)=
## Antithetic time pairs

The heterodyne term changes sign over half a period: $w(t + 1/(2\Delta f), \ell) = -w(t, \ell)$. With
`antithetic = half_period`, every frame renders the time $t$ and its partner $t + 1/(2\Delta f)$ (modulo $T$) and
outputs their mean, so light from static objects cancels within each pair. With `randomReplay`, the partner uses the
same random numbers (random replay), so the two paths are the same up to the motion in between. On the Cornell box
with moving boxes (200 MHz, 50 ms exposure), pairing lowered the error of the heterodyne image 17 to 50 times at
equal render count, and random replay a further 1.1 to 1.3 times.

## Parameters

Measurement:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `modulationFrequency`
  - float
  - Light modulation frequency $f_g$, MHz. (Default: `100`)
* - `heterodyneFrequency`
  - float
  - $\Delta f$, Hz: the light's modulation frequency minus the sensor's. `0` is a homodyne measurement. (Default: `20`)
* - `exposureTime`
  - float
  - Exposure $T$, s. Static light cancels only when $T\,\Delta f$ is a whole number; the pass warns otherwise.
    (Default: `0.05`)
* - `phase`
  - float
  - Sensor phase $\phi$, in periods (`0.25` is 90 degrees). (Default: `0`)
* - `velocities`
  - dictionary
  - The motion of the scene objects; see [Velocities](#doppler-velocities). (Default: none)
```

Time sampling:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `timeSampling`
  - string
  - How each frame's time $t$ is drawn: `uniform` (random) or `stratified` (a golden-ratio sequence over the frames,
    which covers the exposure more evenly). Every pixel of a frame shares its time. (Default: `stratified`)
* - `antithetic`
  - string
  - `none` (one time per frame), `half_period` (also $t + 1/(2\Delta f)$; needs a nonzero `heterodyneFrequency`) or
    `mirror` (also $T - t$, which does not change the sign of the heterodyne term and so does not cancel static
    light). See [Antithetic time pairs](#doppler-tof-antithetic). (Default: `half_period`)
* - `randomReplay`
  - boolean
  - The partner time uses the same random numbers as the first. (Default: `true`)
* - `seed`
  - integer
  - Offsets the time sequence and the random numbers of the paths. (Default: `0`)
```

Sampling and output, as for the [time-gated path tracer](../time_gated/TimeGatedPathTracerInline.md):
`samplesPerPixel` (default `128`), `maxBounces` (default `3`), `computeDirect` (default `false`),
`useImportanceSampling` and `useAlphaTest`. The output is RGB (`useSingleChannel` has no effect). Each frame traces
the pixel-center camera ray itself, in the scene at time $t$, so the pass takes no V-buffer.

(doppler-tof-moving-objects)=
## Moving objects

Every frame sets the scene-graph nodes of the moving objects to their pose at $t$, updates the scene and its
acceleration structure, and puts the objects back at their pose at $t = 0$ after the frame. This needs:

1. **Animated objects.** Falcor bakes static meshes into one merged acceleration structure, which cannot move. Build
   the moving objects as animated, for example `sceneBuilder.addTriangleMesh(mesh, material, True)` in a
   `.pyscene` (the third argument is `isAnimated`). pbrt scenes cannot do this.
2. **One node per moving object.** Load the scene with
   `SceneBuilderFlags.DontMergeMaterials | SceneBuilderFlags.DontOptimizeGraph`; otherwise the graph optimizer can
   merge objects into one node, which then move together.
3. **Rotations about a world-space center**, applied to the node's transform: give each moving object its own
   top-level node.

The pass warns when a named object is static or shares its node with another moving object;
`get_object_names()` returns `(instance, mesh name, material name, movable)` for every object. The camera and the
light do not move.

The scene changes every frame, so an `AccumulatePass` after this pass restarts every frame unless it is created with
`"autoReset": False`.

## Velocity from heterodyne and homodyne

For a path whose length changes at the rate $\mathrm{d}\ell/\mathrm{d}t$, the frequency shift is
$\varepsilon = -f_g\, (\mathrm{d}\ell/\mathrm{d}t) / c$. With complex measurements $C = I_{\phi = 0} + i\, I_{\phi =
0.25}$, a heterodyne ($\Delta f = 1/T$) and a homodyne ($\Delta f = 0$) measurement give

$$
\rho = \operatorname{Re}\frac{C_\mathrm{het}}{C_\mathrm{hom}} = \frac{\varepsilon T}{1 + \varepsilon T},
\qquad
v = -\frac{1}{2}\frac{\mathrm{d}\ell}{\mathrm{d}t} = \frac{c}{2 f_g} \cdot \frac{\rho}{(1 - \rho)\, T},
$$

where $v$ is the velocity along the pixel ray for a light next to the camera. A single phase works too, except where
the homodyne image crosses zero. The relation assumes each path's intensity is constant during the exposure; see the
[Doppler ToF tutorial](../../tutorials/doppler_tof_offline.md) for how close it gets.

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `color` (output)
  - The Doppler ToF measurement of the frame (signed), RGBA32Float. Averaging frames integrates over the exposure.
```

The light is set on the `LaserLight` pass, as for the [time-gated path tracer](#laser).

## Example

```python
testbed.load_scene("cornell-box-moving/scene.pyscene",
                   falcor.SceneBuilderFlags.DontMergeMaterials | falcor.SceneBuilderFlags.DontOptimizeGraph)
graph.create_pass("Light", "LaserLight", {"isLightSourceLaser": False, "laserCollocated": True})
graph.create_pass("Tracer", "DopplerToFPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 3, "computeDirect": True,
    "modulationFrequency": 30.0, "heterodyneFrequency": 1.0 / 0.015, "exposureTime": 0.015,
    "antithetic": "half_period", "randomReplay": True,
    "velocities": {"TallBox": {"linear": [0.0, 0.0, 2.0]}},
})
graph.create_pass("Accumulate", "AccumulatePass", {"autoReset": False})
graph.add_edge("Light", "Tracer")
graph.add_edge("Tracer.color", "Accumulate.input")
```

See the [Doppler ToF tutorial](../../tutorials/doppler_tof_offline.md) for a complete script.
