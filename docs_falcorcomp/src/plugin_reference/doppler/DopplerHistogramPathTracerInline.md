# Doppler spectrum path tracer (`DopplerHistogramPathTracerInline`)

This render pass renders the Doppler spectrum that optical heterodyne detection (OHD) measures with a
single-frequency laser: for every pixel, how much light arrives at each Doppler frequency shift. It evaluates the OHD
path integral of Kim et al. (2025), the same form as the
[transient histogram](../transient/TransientHistogramPathTracerInline.md) but resolved by Doppler shift instead of
path length: every path adds its contribution to the bin of its shift

$$
\Delta f(\bar{x}) = \frac{u(\bar{x})}{\lambda},
\qquad
u(\bar{x}) = \sum_k \eta_k\, (v_k - v_{k+1}) \cdot \hat{d}_k ,
$$

where $\lambda$ is the laser wavelength and $u$ the *path velocity*: over the path's segments $x_k \to x_{k+1}$ (from
the light towards the camera, direction $\hat{d}_k$, refractive index $\eta_k$), the velocity of their endpoints along
the segment. $\Delta f$ is positive when the path shortens, for example for an object coming towards a camera with the
light next to it.

The scene does not move. Every object is given an instantaneous velocity (see
[Velocities](#doppler-velocities)), which only decides the bin of each path; the contribution is that of the static
path.

## Parameters

Spectrum:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `wavelength`
  - float
  - Laser wavelength $\lambda$, nm. (Default: `1550`)
* - `frequencyMin`, `frequencyMax`
  - float
  - Range of Doppler shifts, MHz. Paths outside `[frequencyMin, frequencyMax)` are not recorded.
    (Default: `-50`, `50`)
* - `frequencyBin`
  - integer
  - Number of bins. (Default: `256`)
* - `velocities`
  - dictionary
  - The motion of the scene objects; see [Velocities](#doppler-velocities). (Default: none)
* - `sensorVelocity`
  - float3
  - Velocity of the camera, m/s. (Default: `[0, 0, 0]`)
* - `lightVelocity`
  - float3
  - Velocity of the light's origin (the laser or point light), m/s. (Default: `[0, 0, 0]`)
```

Sampling and output, as for the [transient histogram path tracer](../transient/TransientHistogramPathTracerInline.md):

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
  - Maximum number of surface vertices on a camera path, counting the primary hit. Each vertex is connected to the
    light (the primary hit only with `computeDirect`). Paths are not cut off by length. (Default: `3`)
* - `computeDirect`
  - boolean
  - Include the path camera -> primary hit -> light. (Default: `false`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending a camera path. (Default: `true`)
* - `accumulate`
  - boolean
  - Sum the frames in the spectrum, restarting when the camera moves, a setting changes, or `reset_spectrum()` is
    called; divide by the number of frames for the mean. Off, each frame writes its own spectrum. (Default: `false`)
* - `useSingleChannel`
  - boolean
  - Store one channel per bin, chosen by `singleChannel`. (Default: `false`)
* - `singleChannel`
  - string
  - `luminance`, `red`, `green` or `blue`. (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing rays. (Default: `false`)
* - `outputSize`, `fixedOutputSize`
  - string, integer pair
  - Size of the outputs, as for the transient histogram path tracer. (Default: `Default`, `[512, 512]`)
```

## Light

The light is set on the `LaserLight` pass, as for the [time-gated path tracer](#laser). A lidar has its light next to
the camera: `isLightSourceLaser = false` with `laserCollocated = true` puts a point light at the camera.

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
* - `spectrum` (output)
  - Doppler spectrum, `width x height x frequencyBin`, radiance per MHz. RGBA32Float, or R32Float with
    `useSingleChannel`. `to_numpy()` returns `(frequencyBin, height, width, 4)` (or without the last axis).
* - `color` (output)
  - The steady image (the spectrum summed over all shifts, including those outside the range), RGBA32Float.
```

From Python: `reset_spectrum()`, `set_velocity(...)`, `clear_velocities()` and `get_object_names()`, which returns
`(instance, mesh name, material name)` for every object of the scene.

## Example

```python
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
graph.create_pass("Light", "LaserLight", {"isLightSourceLaser": False, "laserCollocated": True})
graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "maxBounces": 3, "computeDirect": True,
    "wavelength": 1550.0, "frequencyMin": -100.0, "frequencyMax": 100.0, "frequencyBin": 256,
    "velocities": {"TallBox": {"linear": [0.0, 0.0, 20.0]}},
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
```

See the [Doppler spectrum tutorial](../../tutorials/doppler_spectrum_offline.md) for a complete script.
