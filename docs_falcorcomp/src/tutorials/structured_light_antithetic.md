# Structured light: antithetic sampling and the pattern wavelength

This tutorial compares naive and antithetic sampling of a structured-light measurement at equal time for three
wavelengths of a cos stripe pattern. It builds on [Structured light rendering (offline)](structured_light_offline.md),
which explains the projector and the render graph.

```{image} images/structured_light_antithetic.jpg
:alt: Naive and antithetic structured-light rendering at equal time for the pattern wavelengths 0.01, 0.05 and 0.2, with references
:align: center
```

## The antithetic path

`StructuredLightPathTracerInline` weights each path by the projector's pattern $P(\xi)$ at the projector coordinate
$\xi$ of the vertex the projector lights. With `samplingMethod` = `antithetic`, every BSDF-sampled vertex $y$ gets an
antithetic vertex $y'$: the pattern's antithetic map sends $\xi$ to $\xi'$, where the pattern has the opposite sign, and $y'$
is where the projector ray through $\xi'$ hits the scene. For a periodic pattern, $\xi'$ is the mirror image of $\xi$
within the period: about a quarter or three quarters of the period for a cos, so that
$\cos(2\pi\,\xi' / \lambda) = -\cos(2\pi\,\xi / \lambda)$. Unlike CW-ToF, no equation has to be solved: the map is
explicit, and the projector ray gives the antithetic vertex (see [Antithetic sampling](#structured-light-antithetic)).

## The script

The script is that of the [CW-ToF tutorial](cwtof_antithetic.md), with the structured-light pass in place of the
CW-ToF pass. The projector sits 0.4 to the right of the camera and covers the whole box; `naive` uses
`samplingMethod` = `bsdf`.

```{literalinclude} code/structured_light_antithetic.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "def create_graph"
```

## Results

```{list-table}
:header-rows: 1
:widths: 20 25 25 15 15

* - Wavelength
  - Naive (0.3 s)
  - Antithetic (0.3 s)
  - Naive relMSE
  - Antithetic relMSE
* - 0.01
  - 524 spp
  - 331 spp
  - 1.07
  - **0.0639**
* - 0.05
  - 523 spp
  - 332 spp
  - 0.147
  - **0.0422**
* - 0.2
  - 462 spp
  - 366 spp
  - 0.0308
  - **0.0195**
```

The wavelength is in projector coordinates, which span $[0, 1]$ across the projector's field of view: 0.01 gives
100 periods. As for CW-ToF, the finer the pattern, the more the indirect light cancels and the more antithetic
sampling helps: 17 times lower error at the finest pattern. Here it stays ahead even at the coarsest pattern: the
mirror image is at most half a period away, and the projector ray keeps it on nearby geometry.

The full script: {download}`structured_light_antithetic.py <code/structured_light_antithetic.py>`. It takes about
two minutes, most of it for the references.
