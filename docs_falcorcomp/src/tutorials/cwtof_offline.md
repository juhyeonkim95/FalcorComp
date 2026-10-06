# CW-ToF rendering (offline)

This tutorial renders a continuous-wave time-of-flight (CW-ToF) measurement of the Cornell box with
`CWToFPathTracerInline`, with antithetic sampling.

A CW-ToF camera modulates its light and weights each light path by the modulation at the path's
length $\ell$: here $\cos(2\pi\,\ell / \lambda)$ with a wavelength $\lambda = 0.01$, a hundredth
of the box's size. The image shows only the indirect light (`computeDirect` off), which is what
causes multipath errors in real CW-ToF cameras. With such a short wavelength most of it cancels,
leaving rings and stripes where the path length changes slowly: around the points of the walls
closest to the camera, and along the edges.

It uses the same scene file as the other tutorials (see [Modulated light](modulated_index.md)).

```{image} images/cwtof_offline.jpg
:alt: Indirect CW-ToF measurement of the Cornell box
:width: 360px
:align: center
```

The three images below show what this measurement keeps. With the modulation shifted to $[0, 1]$
(`unsignedModulation`), the full measurement (left) is dominated by the direct light, which shows
the rings of the modulation clearly; its indirect part alone (middle) is smooth and dim. The signed, zero-mean
measurement of this tutorial (right, as above) removes the constant part of the modulation, so only
the indirect light that does not cancel is left. Each image has 8,192 samples per pixel; the script
is {download}`modulated_components.py <code/modulated_components.py>` (`python
modulated_components.py cwtof`).

```{image} images/cwtof_components.jpg
:alt: CW-ToF with the modulation in [0, 1] (direct + indirect, indirect) and in [-1, 1] (indirect)
:align: center
```

## 1. Load the scene

```{literalinclude} code/cwtof_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`VBufferRT` finds the primary hits. `LaserLight` places the light, and the execution edge
`add_edge("Light", "Tracer")` makes it run first: with
`isLightSourceLaser = false` it is a point light, and `laserCollocated` puts it at the camera, as
in a CW-ToF camera. The tracer's modulation is set by:

- `waveform` and `modulationWavelength`: the modulation $w(\ell / \lambda - \phi)$, with $\lambda$
  in scene units. `phase` ($\phi$, in periods) shifts it; real CW-ToF cameras take four
  measurements with phases 0, 0.25, 0.5 and 0.75 to recover depth.
- `useAntitheticSampling`: pair every sampled path with an antithetic path half a wavelength
  longer or shorter, whose modulation has the opposite sign (see
  [Antithetic sampling](#cwtof-antithetic)).
- `useSingleChannel`: keep the luminance, as a single signed value per pixel.

`AccumulatePass` averages the frames.

```{literalinclude} code/cwtof_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

```{literalinclude} code/cwtof_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Save the image"
```

## 4. Save the image

The measurement is signed, so it is saved as a NumPy array and shown with a diverging colormap
whose range is the 95th percentile of its magnitude.

```{literalinclude} code/cwtof_offline.py
:language: python
:start-after: "# 4. Save the image"
```

The full script: {download}`cwtof_offline.py <code/cwtof_offline.py>`.

For an equal-time comparison of antithetic and naive sampling, and how it changes with the modulation wavelength, see
[Antithetic sampling for modulated light](modulated_antithetic_index.md).
