# Structured light rendering (offline)

This tutorial renders a structured-light measurement of the Cornell box with
`StructuredLightPathTracerInline`, with antithetic sampling.

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

The three images below show what this measurement keeps. With the modulation shifted to $[0, 1]$
(`unsignedModulation`), the full measurement (left) is dominated by the direct light, which shows
the projected stripes clearly; its indirect part alone (middle) is smooth and dim. The signed, zero-mean
measurement of this tutorial (right, as above) removes the constant part of the modulation, so only
the indirect light that does not cancel is left. Each image has 8,192 samples per pixel; the script
is {download}`modulated_components.py <code/modulated_components.py>` (`python
modulated_components.py structured_light`).

```{image} images/structured_light_components.jpg
:alt: Structured light with the pattern in [0, 1] (direct + indirect, indirect) and in [-1, 1] (indirect)
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
  wider than the camera's 19.5, so it covers the whole view. Without a position, the projector sits
  at the camera itself (`projectorCollocated`).
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

For an equal-time comparison of antithetic and naive sampling, and how it changes with the pattern, see
[Antithetic sampling for modulated light](modulated_antithetic_index.md).
