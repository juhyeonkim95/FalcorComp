# Time-gated path tracer (`TimeGatedPathTracerInline`)

This render pass renders a *time-gated* image: the radiance carried by paths whose total optical
length, from the laser through the scene to the camera, lies near a gate center $t$. For a path
$\bar{\mathbf{x}}$ with optical length $\ell(\bar{\mathbf{x}})$ (segment lengths weighted by the index of
refraction), each pixel estimates

$$
I(t) = \frac{1}{\Delta} \int f(\bar{\mathbf{x}})\, w\!\left(\frac{\ell(\bar{\mathbf{x}}) - t}{\Delta}\right) \mathrm{d}\bar{\mathbf{x}},
$$

where $f$ is the path contribution and $w$ the gate kernel of width $\Delta$ (`timeGateWindow`).
With the `box` kernel, $w(v) = 1$ for $|v| < 1/2$, so $I(t)$ is the radiance per unit path
length averaged over the gate. The other kernels:

(gate-kernels)=
- `tent`: $w(v) = \max(1 - |v|, 0)$.
- `gaussian`: $w(v) \propto e^{-\pi v^2}$, a Gaussian with $\sigma = \Delta / \sqrt{2\pi}$, cut off at
  $3\sigma$ ($|v| \le 3/\sqrt{2\pi}$).
- `exp`: $w(v) \propto e^{-v}$ for $0 \le v \le 3$: a one-sided gate that opens at the center and
  decays over one gate width, cut off at three.
- `exp_two_side`: $w(v) \propto e^{-2|v|}$ for $|v| \le 1.5$: a two-sided exponential that decays over
  half a gate width on each side, cut off at three decay lengths.
- `epanechnikov`: $w(v) = \tfrac{3}{2}\,(1 - 4v^2)$ for $|v| \le 1/2$, the full width $\Delta$ as for the box.
- `perlin`: $w(v) = 2\,(1 - u)^3 (1 + 3u + 6u^2)$ with $u = 2|v| \le 1$, Perlin's smooth step
  $1 - 10u^3 + 15u^4 - 6u^5$ (the kernel of Hachisuka et al. 2010), again over the full width $\Delta$.
- `cos`: $w(v) = \cos(2\pi v)$ over all path lengths.
- `all`: no gating ($w = 1$), so the output is the steady-state radiance divided by $\Delta$.

`box`, `tent`, `gaussian`, `exp`, `exp_two_side`, `epanechnikov` and `perlin` integrate to 1 over $v$
(the truncated kernels are rescaled), so they give images on the same scale.

Camera paths start at the primary hits from `VBufferRT`. With every kernel but `cos` and `all`, a
path stops once it is longer than the end of the kernel.

## Parameters

Time gate:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `timeGateMode`
  - string
  - Gate kernel: `box`, `tent`, `gaussian`, `exp` (one-sided exponential), `exp_two_side`
    (two-sided exponential), `epanechnikov`, `perlin`, `cos` or `all` (no gating). See
    [the kernels](#gate-kernels). (Default: `box`)
* - `timeGateWindow`
  - float
  - Gate width $\Delta$, in path-length units. (Default: `0.05`)
* - `timeMin`, `timeMax`
  - float
  - Range of gate centers. Equal values give a single fixed gate. (Default: `9`, `12`)
* - `timeCenter`
  - float
  - Shortcut for a single fixed gate: sets `timeMin` and `timeMax` to this value, overriding
    them. (Optional)
* - `timeBin`
  - integer
  - Number of gate centers from `timeMin` to `timeMax`. (Default: `512`)
* - `shiftGate`
  - boolean
  - Move the gate to the next center after every frame, wrapping from `timeMax` back to
    `timeMin`. (Default: `false`)
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
  - Camera paths traced per pixel in each frame. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a camera path, counting the primary hit and any vertex
    inserted by an ellipsoidal connection. Each vertex is connected to the laser spot (the
    primary hit only with `computeDirect`). (Default: `3`)
* - `samplingMethod`
  - string
  - How a camera-path vertex is connected to the laser spot: `direct`, `ellipsoidal` or
    `ellipsoidal_direct_mis`. See [Connection sampling](#connection-sampling). (Default: `direct`)
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
  - Importance-sample the BSDF when extending the camera path; otherwise use the material's
    reference sampler (cosine-weighted for standard materials). (Default: `true`)
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
  - Include the shortest path, camera -> primary hit -> laser spot. (Default: `false`)
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

## Gate center

The gate center is `timeMin + (i mod timeBin) / timeBin * (timeMax - timeMin)`, where $i$ is a
gate index that starts at 0. With `timeMin == timeMax` the gate is fixed. The index advances

- every frame, with `shiftGate`, or
- when a script calls `increment_time_gate_frame()`.

Both restart downstream accumulation. `set_time_gate_info(timeMin, timeMax, timeBin)` changes
the range from a script.

(connection-sampling)=
## Connection sampling

Every camera-path vertex $x$ is connected to the laser spot:

- `direct`: connect $x$ to the laser spot.
- `ellipsoidal`: insert a vertex $y$ so that $x \to y \to$ laser spot has a length inside the
  gate. The remaining length is drawn from the gate kernel, and $y$ is placed where the
  ellipsoid with foci $x$ and the laser spot crosses a scene triangle chosen by
  `emissiveSampler`. This finds the rare paths that fit a narrow gate.
- `ellipsoidal_direct_mis`: both, combined with the balance heuristic.

The `cos` and `all` kernels have no length to draw from, and `perlin` has no length sampler, so with
them no ellipsoidal connections are made and both ellipsoidal methods behave like `direct`.

(laser)=
## Laser

The laser is set on a separate `LaserLight` pass, which has no inputs or outputs: every frame it
publishes the laser, which the ToF passes read. Connect it to them with an execution edge,
`graph.add_edge("Laser", "Tracer")` (pass names only), so that it runs first. A pass that finds no laser published
in a frame (no `LaserLight`, one removed from the graph, or no execution edge) warns and uses the default laser.

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `laserPosition`
  - float3
  - Laser position. (Default: `(0, 0, 0)`)
* - `laserDirection`
  - float3
  - Beam direction (normalized). (Default: `(0, 0, 1)`)
* - `laserPower`
  - float3
  - Laser power, or point-light intensity, per color channel. (Default: `(1, 1, 1)`)
* - `laserAngle`
  - float
  - Half-angle of the beam's cone, in degrees; `0` for a collimated beam. Not used by the point light.
    (Default: `0`)
* - `isLightSourceLaser`
  - boolean
  - On: the light is the spot the beam hits, and the beam length adds to the path length. Off:
    a point light at the laser position, which lights the half-space in front of `laserDirection` (nothing
    behind it). (Default: `true`)
* - `laserCollocated`
  - boolean
  - Place the laser at the camera, aimed at its target, instead of at `laserPosition` and
    `laserDirection`. (Default: `false`)
* - `laserVelocity`
  - float3
  - Added to the position after every frame. (Default: `(0, 0, 0)`)
```

`update_laser_info(position, direction)` moves the laser from a script, for example every frame. Any change of the
light (this, `laserVelocity`, new properties, a collocated laser following the camera) restarts downstream
accumulation, so an accumulated image never mixes two laser positions.

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
* - `color` (output)
  - Time-gated image $I(t)$, RGBA32Float. Pixels without a primary hit show the scene's
    environment map background (also divided by $\Delta$) if it has one, otherwise black.
```

## Example

```python
graph.create_pass("Tracer", "TimeGatedPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeGateMode": "box", "timeGateWindow": 0.1, "timeCenter": 17.337,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser", "Tracer")  # run the laser pass first
```

See the [time-gated rendering tutorial](../../tutorials/time_gated_offline.md) for a complete
script.
