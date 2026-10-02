# Direct and global separation

Nayar et al. (2006) separate the light a camera sees into a direct part, light that reached the surface straight
from the source, and a global part, all the rest (interreflections, subsurface scattering, light through glass),
with high-frequency illumination. This page renders the separation scene, a glass dragon, a diffuse armadillo and a
rough metal bunny in a Cornell box, with `StructuredLightPathTracerInline` and shifted checkerboards.

```{image} images/direct_global_separation.jpg
:alt: Direct and global light of the separation scene, true and separated with naive and antithetic sampling, with error maps
:align: center
```

## Shifted checkerboards

The projector shows a binary checkerboard of 64 x 64 cells, shifted over a 5 x 5 grid of fifths of a cell, so that
every point is lit in some of the 25 images and dark in others. The pass renders the signed pattern $P = \pm 1$, the
difference of the checkerboard and its inverse, so a measurement is

$$
S = D\,P + G_P,
$$

where $D$ is the direct light and $G_P$ the global light under the zero-mean pattern, which nearly cancels for fine
cells. A pixel is lit by the checkerboard or by its inverse in every image, so over all images $\max |S| = D$, and the
global light is the white image minus it:

```{literalinclude} code/direct_global_separation.py
:language: python
:start-after: "# 5. Separate"
:end-before: "results = {}"
```

## Results

Each checkerboard image is rendered for 0.4 seconds.

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - Method
  - Samples per pixel per image
  - Direct relMSE
  - Global relMSE
* - Naive
  - 316
  - **0.032**
  - **0.22**
* - Antithetic
  - 160
  - 0.041
  - 0.28
```

The separation finds the global light of the glass dragon, lit through the glass, and of the armadillo, lit by the
walls and the other objects; the remaining noise is in the global light of the dragon and of the floor under it. In
this scene antithetic sampling (each sampled vertex paired with the vertex lit by the next checkerboard cell) does
not help: most of the global light passes through the glass dragon or off the metal bunny, and vertices sampled from
their near-specular lobes have no partner, while an antithetic frame costs twice as much. In diffuse scenes it does
help: under the same checkerboards, the indirect light of the Cornell box and of the diffuse bunny scene renders
with a 3 to 9 times lower error at equal time.

The full script: {download}`direct_global_separation.py <code/direct_global_separation.py>`. Run it next to the
unzipped `cornell-box-separation` folder; it takes about a minute.
