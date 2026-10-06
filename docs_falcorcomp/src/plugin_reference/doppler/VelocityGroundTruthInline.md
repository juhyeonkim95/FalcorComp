# Ground-truth velocity (`VelocityGroundTruthInline`)

This render pass renders a velocity map (m/s per pixel) of the direct path camera -> primary hit -> light, to check
the Doppler passes against. The primary hit is that of the pixel-center camera ray. Three velocities are available,
and they differ:

```{list-table}
:header-rows: 1
:widths: 18 52 30

* - `mode`
  - Velocity
  - Objects move?
* - `doppler`
  - Half the path velocity $u$ of the direct path, as
    [`DopplerHistogramPathTracerInline`](DopplerHistogramPathTracerInline.md) bins it: the velocity of the hit surface
    point (and of the camera and the light) along the path's segments. With the light next to the camera, the hit
    point's velocity towards the camera.
  - no
* - `path_length`
  - $-(\ell(\mathrm{d}t) - \ell(0)) / (2\,\mathrm{d}t)$: how fast the length of the direct path along the *fixed*
    pixel ray changes, as [`DopplerToFPathTracerInline`](DopplerToFPathTracerInline.md) measures it. The pixel ray
    meets a moving surface at a different point at $\mathrm{d}t$, so on surfaces seen at a grazing angle this is much
    larger than the `doppler` velocity.
  - yes, to their pose at `dt` (see [Moving objects](#doppler-tof-moving-objects))
* - `projection`
  - The hit point's velocity along `direction`, for example the objects' velocity along the camera axis.
  - no
```

The visibility of the light is ignored. Pixels without a hit are NaN; with `path_length`, so are pixels whose ray
hits another object at `dt` than at time 0 (an object edge, where the length difference is not a velocity).

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `mode`
  - string
  - `doppler`, `path_length` or `projection`. (Default: `doppler`)
* - `velocities`
  - dictionary
  - The motion of the scene objects; see [Velocities](#doppler-velocities). (Default: none)
* - `dt`
  - float
  - `path_length`: the time step, s. (Default: `0.001`)
* - `direction`
  - float3
  - `projection`: the direction, normalized by the pass. (Default: `[0, 0, 1]`)
* - `sensorVelocity`, `lightVelocity`
  - float3
  - `doppler`: velocity of the camera and of the light's origin, m/s. (Default: `[0, 0, 0]`)
```

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `velocity` (output)
  - Velocity of the direct path, m/s, R32Float; NaN without a hit.
```

The light is set on the `LaserLight` pass. From Python: `set_velocity(...)` and `get_object_names()`.

## Example

```python
graph.create_pass("Light", "LaserLight", {"isLightSourceLaser": False, "laserCollocated": True})
graph.create_pass("Truth", "VelocityGroundTruthInline", {
    "mode": "path_length", "dt": 1e-3,
    "velocities": {"TallBox": {"linear": [0.0, 0.0, 2.0]}},
})
graph.add_edge("Light", "Truth")
graph.mark_output("Truth.velocity")
```

The [Doppler ToF tutorial](../../tutorials/doppler_tof_offline.md) compares the three modes.
