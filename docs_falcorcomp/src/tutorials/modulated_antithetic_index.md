# Antithetic sampling for modulated light

These tutorials look more closely at antithetic sampling for the [modulated-light](modulated_index.md) render
passes. With a high-frequency modulation, the light that reaches a pixel along many paths largely cancels out, and
independent samples of it, with random signs, cancel only slowly. Antithetic sampling pairs every sampled path with a
nearby path whose modulation has the opposite sign, so each pair cancels the way the true signal does.

Each tutorial compares antithetic and naive sampling at equal rendering time, on the indirect light of the Cornell
box (the scene of the [ToF rendering](index.md) tutorials), with references rendered by naive sampling with 262,144
samples per pixel. The error is the relative mean squared error,
$\mathrm{relMSE} = \overline{(I - I_\mathrm{ref})^2} / \overline{I_\mathrm{ref}^2}$. The numbers were measured on an
NVIDIA GeForce RTX 3090 with Vulkan; frame counts and errors depend on the GPU. The scripts need matplotlib.

````{grid} 1 2 2 3
:gutter: 3

```{grid-item-card} CW-ToF: modulation wavelength
:img-top: images/thumbnails/cwtof_antithetic_thumb.jpg
:img-alt: Antithetic CW-ToF rendering of the Cornell box
:link: cwtof_antithetic
:link-type: doc

Find the partner by Newton's method on barycentric coordinates, and see how the gain changes with the wavelength.
```

```{grid-item-card} Structured light: pattern wavelength
:img-top: images/thumbnails/structured_light_antithetic_thumb.jpg
:img-alt: Antithetic structured-light rendering of the Cornell box
:link: structured_light_antithetic
:link-type: doc

Mirror the projector coordinate within the period of a cos pattern, at three pattern wavelengths.
```

```{grid-item-card} Structured light: binary codes
:img-top: images/thumbnails/structured_light_codes_thumb.jpg
:img-alt: Antithetic rendering with an arbitrary binary code
:link: structured_light_codes
:link-type: doc

Aperiodic codes: XOR codes and random balanced blocks, and arbitrary codes with optimal-transport and scale-based
maps.
```
````

```{toctree}
:hidden:

cwtof_antithetic
structured_light_antithetic
structured_light_codes
```
