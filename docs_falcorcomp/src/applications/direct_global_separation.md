# Direct and global separation

Nayar et al. (2006) separate the light a camera sees into a direct part, light that reached the surface straight
from the source, and a global part, all the rest (interreflections, light through glass, ...), with high-frequency
illumination. This page renders the separation scene, a glass dragon, a white armadillo and a rough gold bunny in a
Cornell box, with `StructuredLightPathTracerInline` and shifted checkerboards, and compares naive and antithetic
sampling of the indirect light.

```{image} images/direct_global_separation.jpg
:alt: Direct and global light of the separation scene, true and separated with naive and antithetic sampling, with squared-error maps
:align: center
```

## Setup

- **Projector**: collocated with the camera (at its position, looking the same way), with a field of view a little
  wider than the camera's (the tangent of its half angle is 0.2). It lights everything the camera sees, without
  shadows.
- **Patterns**: a binary checkerboard of 1024 x 1024 cells, about one pixel each, shifted over a 5 x 5 grid of
  fifths of a cell, and the inverse of each: 50 images.
- **Images**: 1024 x 1024, with primary rays jittered over each pixel (`VBufferRT` with 32 Halton positions). The
  direct light of each pattern is rendered first, once (128 samples per pixel); only its indirect light, the noisy
  part, is rendered with each method: 64 samples per pixel for naive sampling, 32 for antithetic sampling, whose
  samples each also trace their antithetic path.
- **Glass**: the projector lights a surface only on the side its path arrives from, so it does not light the inside
  of the glass dragon through its surface; the dragon's global light is the light of the walls and the other
  objects, seen through the glass.

```{literalinclude} code/direct_global_separation.py
:language: python
:start-after: "# 2. The projector and the render graph"
:end-before: "graph = testbed.create_render_graph"
```

## Separation

The pass renders the signed pattern $P = \pm 1$, so the image under the binary checkerboard, 1 where $P = 1$ and 0
elsewhere, is half the sum of the white image and the signed one:

```{literalinclude} code/direct_global_separation.py
:language: python
:start-after: "# 4. Capture the checkerboards and their inverses"
:end-before: "# 5. Separate"
```

Under a fine pattern that lights half the scene, a lit point receives its direct light and half its global light,
a dark one only half its global light. Over the 50 images every point is lit in some and dark in others, so the
brightest image minus the darkest is the direct light, and twice the darkest is the global light:

```{literalinclude} code/direct_global_separation.py
:language: python
:start-after: "# 5. Separate (Nayar et al.)"
:end-before: "def luminance"
```

## Results

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - Indirect light
  - Samples per pixel per image
  - Direct MSE
  - Global MSE
* - Naive
  - 64
  - 3.0e-6
  - 3.7e-6
* - Antithetic
  - 32
  - **1.5e-6**
  - **1.4e-6**
```

The maximum and the minimum over 50 images pick up the noise of the indirect light: with naive sampling, the noise
raises the brightest image and lowers the darkest one, so the direct light comes out too bright and the global light
too dark, most of all on the glass dragon and on the floor under it, where the global light is strong. Antithetic
sampling pairs each sampled vertex with the vertex lit by the neighboring cell, of the opposite sign, so the indirect
light cancels pair by pair; with half the samples, the error drops 2 times for the direct light and almost 3 times
for the global light. The error maps show the squared error of the luminance, from 0 (black) to $10^{-4}$ (yellow);
the images are shown filtered, at a third of their resolution.

The full script: {download}`direct_global_separation.py <code/direct_global_separation.py>`. Run it next to the
unzipped `cornell-box-separation` folder; it takes a few minutes.
