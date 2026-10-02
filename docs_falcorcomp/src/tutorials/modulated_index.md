# Modulated light

Some imaging systems encode information in how their light varies. A **continuous-wave
time-of-flight** (CW-ToF) camera modulates its light source in time and correlates the returning
light with a reference signal, so the measurement depends on the phase of each path's length. A
**structured light** system projects a spatial pattern, so the measurement depends on the pattern
value where each path is lit. Both measure a path integral weighted by a modulation term $m$:

$$
I = \int f(\bar{\mathbf{x}})\, m(\bar{\mathbf{x}})\, \mathrm{d}\bar{\mathbf{x}}.
$$

| Measurement | Modulation $m(\bar{\mathbf{x}})$ | Render pass |
|---|---|---|
| **CW-ToF** | a periodic waveform of the path length, $w(\ell(\bar{\mathbf{x}}) / \lambda - \phi)$ | `CWToFPathTracerInline` |
| **Structured light** | the projector pattern at the path's projector coordinates, $P(\xi(\bar{\mathbf{x}}))$ | `StructuredLightPathTracerInline` |

By default both passes use the zero-mean part of the modulation, in $[-1, 1]$ (the constant part
is an ordinary image; `unsignedModulation` adds it back). With a high-frequency modulation, the
indirect light, which reaches a pixel along many paths of different lengths or projector
coordinates, largely cancels out. That is why these systems use high frequencies, but it also makes
the indirect part hard to render: independent samples have random signs and cancel only slowly.
Both passes therefore support **antithetic sampling**: every sampled path is paired with a
geometrically close path whose modulation has the opposite sign, so the pair cancels the way the
true signal does, and the two are combined with multiple importance sampling.

The tutorials render the indirect part only (`computeDirect` off), as a signed image shown with a
diverging colormap (0 in white, positive in red, negative in blue), and compare antithetic sampling
with naive sampling at equal rendering time.

- **Scene:** the Cornell box without its area light, as in the [ToF rendering](index.md)
  tutorials. Download {download}`scene-v4-nolight.pbrt <scenes/cornell-box/scene-v4-nolight.pbrt>`
  and save it as `cornell-box/scene-v4-nolight.pbrt` next to the scripts.
- **Light:** for CW-ToF, a point light at the camera, set on `LaserLight`; for structured light,
  a projector next to the camera, set on the render pass.
- **Extra package:** the scripts save the signed images with matplotlib (`pip install matplotlib`).

## Tutorials

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} CW-ToF rendering (offline)
:img-top: images/thumbnails/cwtof_offline_thumb.jpg
:img-alt: Indirect CW-ToF measurement of the Cornell box
:link: cwtof_offline
:link-type: doc

Render the indirect CW-ToF measurement with `CWToFPathTracerInline`, and compare antithetic and
naive sampling at equal time.
```

```{grid-item-card} Structured light rendering (offline)
:img-top: images/thumbnails/structured_light_offline_thumb.jpg
:img-alt: Indirect structured-light measurement of the Cornell box
:link: structured_light_offline
:link-type: doc

Project fine sinusoidal stripes with `StructuredLightPathTracerInline`, and compare antithetic and
naive sampling at equal time.
```
````

For more, see [Antithetic sampling for modulated light](modulated_antithetic_index.md) (the modulation wavelength,
the Newton-based shift, binary codes) and the [applications](../applications/modulated_index.md) (depth
reconstruction, direct and global separation).

```{toctree}
:hidden:

cwtof_offline
structured_light_offline
```
