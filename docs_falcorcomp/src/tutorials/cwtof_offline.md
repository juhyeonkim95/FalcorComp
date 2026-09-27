# CW-ToF rendering (offline)

This tutorial renders a continuous-wave time-of-flight (CW-ToF) measurement of the Cornell box with
`CWToFPathTracerInline`, and compares antithetic and naive sampling at equal rendering time.

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
- `useAntitheticSampling`: pair every sampled path with a partner half a wavelength longer or
  shorter, whose modulation has the opposite sign (see
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

## Equal-time comparison

The comparison script builds the same render graph, renders it with and without antithetic
sampling for 0.3 seconds each at 256 x 256, and compares both with a reference rendered by naive
sampling with 262,144 samples per pixel. The error is the relative mean squared error,
$\mathrm{relMSE} = \overline{(I - I_\mathrm{ref})^2} / \overline{I_\mathrm{ref}^2}$.

Each method first renders a frame that compiles its shaders, then warms up for a second, so the GPU
runs at full speed when the timing starts:

```{literalinclude} code/cwtof_equal_time.py
:language: python
:start-after: "# 3. Render each method for the same time"
:end-before: "# 4. Render a reference"
```

```{image} images/cwtof_equal_time.jpg
:alt: Equal-time comparison of naive and antithetic CW-ToF rendering with a reference
:align: center
```

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - Method (0.3 seconds)
  - Frames
  - Samples per pixel
  - relMSE
* - Naive
  - 366
  - 2,928
  - 0.130
* - Antithetic
  - 289
  - 2,312
  - 0.0064
```

An antithetic frame costs about 25% more, since it finds and evaluates a partner for every sampled
path, but in the same time its error is 20 times lower: naive sampling shows only noise, while
antithetic sampling already shows the rings and stripes of the reference. The advantage shrinks for
longer wavelengths, where the partner, half a wavelength away, is no longer similar to its path.
These numbers were measured on an NVIDIA GeForce RTX 3090 with Vulkan; frame counts and errors
depend on the GPU.

The full comparison script, which also saves the image above:
{download}`cwtof_equal_time.py <code/cwtof_equal_time.py>`. It takes about 45 seconds, most of it
for the reference.
