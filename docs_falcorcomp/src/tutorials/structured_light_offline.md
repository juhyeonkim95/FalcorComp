# Structured light rendering (offline)

This tutorial renders a structured-light measurement of the Cornell box with
`StructuredLightPathTracerInline`, and compares antithetic and naive sampling at equal rendering
time.

A projector next to the camera shows fine vertical stripes, $\cos(2\pi\,u / \lambda)$ with
$\lambda = 0.01$ in projector coordinates: 100 periods across its field of view. The image shows
only the indirect light (`computeDirect` off), which is what corrupts real structured-light
measurements. With such fine stripes most of it cancels; what is left varies slowly, except near
the edges, where light bounces between nearby surfaces.

It uses the same scene file as the other tutorials (see [Modulated light](modulated_index.md)).

```{image} images/structured_light_offline.jpg
:alt: Indirect structured-light measurement of the Cornell box
:width: 360px
:align: center
```

## 1. Load the scene

```{literalinclude} code/structured_light_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`VBufferRT` finds the primary hits; the projector is set on the tracer itself, so no light pass is
needed:

- `projectorPosition`, `projectorDirection`, `projectorFov`, `projectorIntensity`: a pinhole
  projector 0.4 to the right of the camera, looking the same way, with a 30-degree field of view,
  wider than the camera's 19.5, so it covers the whole view.
- `pattern`, `waveform`, `patternAxis`, `patternWavelength`: sinusoidal stripes along the
  projector's $u$ axis (vertical stripes), with a period of 0.01 in projector coordinates. Gray,
  XOR, checkerboard and arbitrary binary codes are also available (see the
  [plugin reference](../plugin_reference/modulated/StructuredLightPathTracerInline.md)).
- `samplingMethod = antithetic`: pair every sampled path with the point lit through the mirror
  image of its stripe position, where the pattern has the opposite sign (see
  [Antithetic sampling](#structured-light-antithetic)).
- `useSingleChannel`: keep the luminance, as a single signed value per pixel.

`AccumulatePass` averages the frames.

```{literalinclude} code/structured_light_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

```{literalinclude} code/structured_light_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Save the image"
```

## 4. Save the image

The measurement is signed, so it is saved as a NumPy array and shown with a diverging colormap
whose range is the 95th percentile of its magnitude.

```{literalinclude} code/structured_light_offline.py
:language: python
:start-after: "# 4. Save the image"
```

The full script: {download}`structured_light_offline.py <code/structured_light_offline.py>`.

## Equal-time comparison

The comparison script works like the [CW-ToF one](cwtof_offline.md): it renders the same graph with
`samplingMethod` set to `bsdf` (naive) and `antithetic` for 0.3 seconds each at 256 x 256, after
compiling and warming up, and compares both with a naive reference with 262,144 samples per pixel.

```{image} images/structured_light_equal_time.jpg
:alt: Equal-time comparison of naive and antithetic structured-light rendering with a reference
:align: center
```

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - `samplingMethod` (0.3 seconds)
  - Frames
  - Samples per pixel
  - relMSE
* - `bsdf` (naive)
  - 393
  - 3,144
  - 0.0782
* - `antithetic`
  - 303
  - 2,424
  - 0.0048
```

An antithetic frame costs about 30% more, since it traces a projector ray to the partner and checks
that it is visible, but in the same time its error is 16 times lower. These numbers were measured on
an NVIDIA GeForce RTX 3090 with Vulkan; frame counts and errors depend on the GPU.

The full comparison script, which also saves the image above:
{download}`structured_light_equal_time.py <code/structured_light_equal_time.py>`. It takes about
45 seconds, most of it for the reference.
