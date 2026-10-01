# Doppler-gated path tracer (`DopplerGatedPathTracerInline`)

This render pass renders the light whose Doppler frequency shift falls inside a gate, as measured by optical
heterodyne detection (OHD) with a single-frequency laser. It relates to
[`DopplerHistogramPathTracerInline`](DopplerHistogramPathTracerInline.md) as the
[time-gated path tracer](../time_gated/TimeGatedPathTracerInline.md) relates to the transient histogram: one image
for one gate instead of the whole spectrum. Every path is weighted by a gate kernel $g$ at its Doppler shift

$$
\Delta f(\bar{\mathbf{x}}) = \frac{u(\bar{\mathbf{x}})}{\lambda},
\qquad
I = \frac{1}{w} \int f(\bar{\mathbf{x}})\, g\!\left(\frac{\Delta f(\bar{\mathbf{x}}) - f_c}{w}\right) \mathrm{d}\bar{\mathbf{x}},
$$

with the path velocity $u$ of the [Doppler spectrum path tracer](DopplerHistogramPathTracerInline.md), the gate
center $f_c$ and the gate width $w$ (MHz). Dividing by $w$ gives radiance per MHz, the unit of the spectrum: a box
gate one bin wide at the center of a bin gives that bin of the spectrum.

The scene does not move. Every object is given an instantaneous velocity (see
[Velocities](#doppler-velocities)), which only decides the shift of each path. A light connection outside the gate
contributes nothing, so its visibility ray is skipped: narrow gates are cheaper than the full spectrum.

## Parameters

Gate:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `frequencyCenter`
  - float
  - Center $f_c$ of a fixed gate, MHz. Sets `frequencyMin` = `frequencyMax`. Positive shifts come from paths that
    shorten, for example an object approaching a camera with the light next to it. (Default: `0`)
* - `frequencyGateWindow`
  - float
  - Gate width $w$, MHz. The output is divided by it. (Default: `1`)
* - `frequencyGateMode`
  - string
  - Gate kernel, the same as the time-gated path tracer's: `box`, `tent`, `gaussian`, `exp` (one-sided
    exponential), `exp_two_side` (two-sided exponential), `cos` or `all` (no gating); see
    [the kernels](#gate-kernels), with the shift in place of the path length. `epanechnikov` and `perlin` are also
    accepted, but act like `all`. (Default: `box`)
* - `shiftGate`
  - boolean
  - Move the gate one step per frame from `frequencyMin` towards `frequencyMax`, then start again. (Default: `false`)
* - `frequencyMin`, `frequencyMax`
  - float
  - Range of gate centers scanned by `shiftGate`, MHz. (Default: `0`, `0`)
* - `frequencyBin`
  - integer
  - Number of gate positions in the scan. (Default: `512`)
```

Doppler shift:

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `wavelength`
  - float
  - Laser wavelength $\lambda$, nm. (Default: `1550`)
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

Sampling and output, as for the [Doppler spectrum path tracer](DopplerHistogramPathTracerInline.md):
`samplesPerPixel` (default `128`), `maxBounces` (default `3`), `computeDirect` (default `false`),
`useImportanceSampling`, `useAlphaTest`, and `useSingleChannel` with `singleChannel`, which write the chosen channel
to all three channels of the output.

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
* - `color` (output)
  - The Doppler-gated image of the frame, radiance per MHz, RGBA32Float. Average frames with `AccumulatePass`.
```

From Python: `set_velocity(...)`, `clear_velocities()`, `get_object_names()`, which returns
`(instance, mesh name, material name, movable)` for every object of the scene, and, for scans,
`increment_frequency_gate_frame()` and `set_frequency_gate_info(frequency_min, frequency_max, frequency_bin)`.

## Example

The tall box of the Cornell box approaches at 20 m/s and the short box recedes; a Gaussian gate 2 MHz wide at
+25.8 MHz ($2v/\lambda$ at 1550 nm) keeps the light that the tall box reflected once:

```python
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Light", "LaserLight", {"isLightSourceLaser": False, "laserCollocated": True})
graph.create_pass("Tracer", "DopplerGatedPathTracerInline", {
    "samplesPerPixel": 64, "maxBounces": 3, "computeDirect": True, "wavelength": 1550.0,
    "frequencyCenter": 25.8, "frequencyGateWindow": 2.0, "frequencyGateMode": "gaussian",
    "velocities": {"TallBox": {"linear": [0.0, 0.0, 20.0]}, "ShortBox": {"linear": [0.0, 0.0, -20.0]}},
})
graph.create_pass("Accumulate", "AccumulatePass", {})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Light", "Tracer")
graph.add_edge("Tracer.color", "Accumulate.input")
graph.mark_output("Accumulate.output")
```

The [Doppler spectrum tutorial](../../tutorials/doppler_spectrum_offline.md) renders the same scene as a spectrum.
