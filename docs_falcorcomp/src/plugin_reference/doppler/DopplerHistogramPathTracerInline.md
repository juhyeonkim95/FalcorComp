# Doppler spectrum path tracer (`DopplerHistogramPathTracerInline`)

This render pass renders the spectrum that optical heterodyne detection (OHD) measures: for every pixel, how much
light arrives at each beat frequency. With a single-frequency laser, the beat frequency is the Doppler frequency
shift; with a chirped laser, as in an FMCW lidar, it also depends on the path length (see [FMCW](#doppler-fmcw)). It
evaluates the OHD path integral of Kim et al. (2025), the same form as the
[transient histogram](../transient/TransientHistogramPathTracerInline.md) but resolved by Doppler shift instead of
path length: every path adds its contribution to the bin of its shift

$$
\Delta f(\bar{\mathbf{x}}) = \frac{u(\bar{\mathbf{x}})}{\lambda},
\qquad
u(\bar{\mathbf{x}}) = \sum_k \eta_k\, (v_k - v_{k+1}) \cdot \hat{d}_k ,
$$

where $\lambda$ is the laser wavelength and $u$ the *path velocity*: over the path's segments $x_k \to x_{k+1}$ (from
the light towards the camera, direction $\hat{d}_k$, refractive index $\eta_k$), the velocity of their endpoints along
the segment. $\Delta f$ is positive when the path shortens, for example for an object coming towards a camera with the
light next to it.

The scene does not move. Every object is given an instantaneous velocity (see
[Velocities](#doppler-velocities)), which only decides the bin of each path; the contribution is that of the static
path.

(doppler-fmcw)=
## FMCW

With `chirpBandwidth` $B > 0$, the laser frequency sweeps by $B$ over `chirpDuration` $T$, up and then down (a
triangular chirp). A path's beat frequency then also has a range term, from its optical path length
$l(\bar{\mathbf{x}}) = \sum_k \eta_k \lVert x_{k+1} - x_k \rVert$ (Kim et al. 2025, Eqs. 9 and 33):

$$
f_R(\bar{\mathbf{x}}) = \frac{B}{T}\,\frac{l(\bar{\mathbf{x}})}{c},
\qquad
f_\text{up} = f_R - \Delta f,
\qquad
f_\text{down} = f_R + \Delta f .
$$

The pass writes the up-chirp spectrum to `spectrum` and the down-chirp spectrum to `spectrumDown`, on the same bins.
A peak's position thus mixes distance and velocity, and the two chirps separate them: with the light next to the
camera, a surface at distance $d$ moving towards the camera at $v$ has $l = 2d$ and $\Delta f = 2v/\lambda$, so

$$
d = \frac{c\,T}{4B}\left(f_\text{up} + f_\text{down}\right),
\qquad
v = \frac{\lambda}{4}\left(f_\text{down} - f_\text{up}\right).
$$

With $B$ in GHz, $T$ in µs and scene units in meters, $f_R$ is $3.336\,B/T$ MHz per meter of path length. The bins
keep the sign of $f_R \mp \Delta f$; a range from 0 MHz covers every path whose range term exceeds its Doppler shift.

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
* - `chirpBandwidth`
  - float
  - Chirp bandwidth $B$, GHz: the laser frequency sweeps by $B$ over `chirpDuration`, up and then down
    ([FMCW](#doppler-fmcw)). `0` is a single-frequency laser. (Default: `0`)
* - `chirpDuration`
  - float
  - Duration $T$ of each sweep, µs. Used when `chirpBandwidth` is positive. (Default: `10`)
* - `frequencyMin`, `frequencyMax`
  - float
  - Range of Doppler shifts (with a chirp, of beat frequencies), MHz. Paths outside `[frequencyMin, frequencyMax)`
    are not recorded. (Default: `-50`, `50`)
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
  - Sum the frames in the spectrum, restarting when the camera moves, a setting changes, the render graph is
    recompiled (e.g. on a resize), or `reset()` is called; divide by the number of frames for the mean. Off,
    each frame writes its own spectrum. (Default: `false`)
* - `useSingleChannel`
  - boolean
  - Store one channel per bin, chosen by `singleChannel`; `color` holds the same channel in all
    three channels. (Default: `false`)
* - `singleChannel`
  - string
  - `luminance`, `red`, `green` or `blue`. (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing rays. (Default: `false`)
* - `outputSize`, `fixedOutputSize`
  - string, integer pair
  - Size of the outputs, as for the transient histogram path tracer; the `vbuffer` input must have the same size.
    (Default: `Default`, `[512, 512]`)
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
  - Doppler spectrum (with a chirp, the up-chirp spectrum), `width x height x frequencyBin`, radiance per MHz.
    RGBA32Float (the alpha channel counts the samples that added light to the bin), or R32Float with
    `useSingleChannel`. `to_numpy()` returns `(frequencyBin, height, width, 4)` (or without the last axis).
* - `spectrumDown` (output, with a chirp)
  - The down-chirp spectrum, as `spectrum`.
* - `color` (output)
  - The steady image (the spectrum summed over all shifts, including those outside the range), RGBA32Float.
```

From Python: `reset()`, `set_velocity(...)`, `clear_velocities()` and `get_object_names()`, which returns
`(instance, mesh name, material name, movable)` for every object of the scene.

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

An FMCW lidar with a 1 GHz chirp over 1 µs, whose beat frequencies fall between 0 and 100 MHz in this scene:

```python
graph.create_pass("Tracer", "DopplerHistogramPathTracerInline", {
    "samplesPerPixel": 64, "maxBounces": 3, "computeDirect": True,
    "wavelength": 1550.0, "chirpBandwidth": 1.0, "chirpDuration": 1.0,
    "frequencyMin": 0.0, "frequencyMax": 100.0, "frequencyBin": 512,
    "velocities": {"TallBox": {"linear": [0.0, 0.0, 20.0]}},
})
graph.mark_output("Tracer.spectrum")      # up-chirp
graph.mark_output("Tracer.spectrumDown")  # down-chirp
```

See the [Doppler spectrum tutorial](../../tutorials/doppler_spectrum_offline.md) and the
[FMCW lidar tutorial](../../tutorials/fmcw_lidar_offline.md) for complete scripts.
