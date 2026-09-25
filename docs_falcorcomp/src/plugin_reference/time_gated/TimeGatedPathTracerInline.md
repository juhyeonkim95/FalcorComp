# Time-gated path tracer (`TimeGatedPathTracerInline`)

This render pass renders a *time-gated* image: the radiance carried by paths whose total optical
length, from the laser through the scene to the camera, lies near a gate center $t$. For a path
$\bar{x}$ with optical length $\ell(\bar{x})$ (segment lengths weighted by the index of
refraction), each pixel estimates

$$
I(t) = \frac{1}{\Delta} \int f(\bar{x})\, w\!\left(\frac{\ell(\bar{x}) - t}{\Delta}\right) \mathrm{d}\bar{x},
$$

where $f$ is the path contribution and $w$ the gate kernel of width $\Delta$ (`timeGateWindow`).
With the `box` kernel, $w(v) = 1$ for $|v| < 1/2$, so $I(t)$ is the radiance per unit path
length averaged over the gate. `tent` uses $w(v) = \max(1 - |v|, 0)$, and `cos` uses
$w(v) = \cos(2\pi v)$ over all path lengths. `all` does not gate ($w = 1$), so the output is the
steady-state radiance divided by $\Delta$.

Camera paths start at the primary hits from `VBufferRT`. With `box` and `tent`, a path stops once
it is longer than the gate's upper edge.

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
  - Gate kernel: `box`, `tent`, `cos` or `all` (no gating). (Default: `box`)
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
    inserted by an ellipsoidal connection. Each vertex is connected to the laser spot.
    (Default: `3`)
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
  - How an ellipsoidal connection picks the scene triangle to place its vertex on: `Uniform`,
    `LightBVH` or `Power`. Unused with `direct`. (Default: `LightBVH`)
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

(laser)=
## Laser

The laser is set on `LaserVBufferRT`: its position, direction, power and cone angle
(`laserAngle`, 0 for a collimated beam), `laserCollocated` to place it at the camera, and
`isLightSourceLaser`. With `isLightSourceLaser` (the default), the light is the spot the beam
hits, and the beam length adds to the path length; otherwise it is a point light at the laser
position.

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
* - `laservbuffer` (input)
  - Laser hit, from `LaserVBufferRT`.
* - `laserviewW` (input, optional)
  - Laser ray direction, from `LaserVBufferRT`.
* - `color` (output)
  - Time-gated image $I(t)$, RGBA32Float.
```

## Example

```python
graph.create_pass("Tracer", "TimeGatedPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeGateMode": "box", "timeGateWindow": 0.1, "timeCenter": 17.337,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
graph.add_edge("Laser.viewW", "Tracer.laserviewW")
```

See the [time-gated rendering tutorial](../../tutorials/time_gated_offline.md) for a complete
script.
