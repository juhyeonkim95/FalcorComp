# Structured illumination

LSCI mixes the flow at all the depths its light reaches. Structured illumination separates them. Fringes of a high
spatial frequency survive only in light that comes back from near the surface; light that goes deeper spreads sideways
and washes them out. Spatial frequency domain imaging (SFDI, Cuccia et al. 2009) uses this to measure the optical
properties of tissue at chosen depths, and its coherent version combines it with speckle contrast for flow. This page
renders two blood vessels that cross at very different depths. Plain LSCI shows both; the speckle contrast of the light
that keeps the fringes shows only the shallow one, and the two together give an image of flow and depth.

```{image} images/lsci_structured_depth.jpg
:alt: The two vessels in 3D, the speckle contrast under uniform light, and an image of flow colored by depth
:align: center
```

## Fringes, demodulated

The point light at the camera becomes a projector of fringes along x: `patternFrequency` and `patternPhase` of
`LaserLight` scale its light by $\frac{1}{2}\left(1 + \cos(2\pi f x + \phi)\right)$ on the tissue (see
[Laser](#laser); `patternFrequency` is $f$ times the light's height, as it is set at 1 m from the light). Three
phases, $\phi_j = 0, 2\pi/3, 4\pi/3$, demodulate the images as in SFDI: their mean is the image under uniform light
(DC), and their first harmonic the light that keeps the fringes (AC) ([step 5](#lsci-structured-fringes) shows the
images). The Doppler spectra demodulate the same way, bin by bin:

$$
C(f_D) = \frac{4}{3} \sum_j S_j(f_D)\, e^{-i \phi_j},
$$

a complex spectrum whose modulus is the amplitude of the fringes in each bin. Its speckle contrast follows as on the
[first page](lsci_basics.md), with $A[m] = \operatorname{Re} \sum_k \overline{C_a[k]}\, C_b[k + m]$ from two independent
renders $a$ and $b$, and $I^2 = \operatorname{Re}\, \overline{\sum C_a} \sum C_b$.

The AC light is a small part of the light. Rendered one phase at a time, each image would carry the noise of all the
light into the difference. `patternPhaseShift` instead puts the three phases into the three color channels of one
render, so that they come from the same paths, and the demodulation cancels the uniform light path by path: the phases
are sampled together, as antithetic sampling pairs the parts of a pattern. The tracer renders color for this (no
`useSingleChannel`).

At the frequency $f$, the AC light fades with depth as $e^{-\mu' z}$, with
$\mu' = \sqrt{3 \mu_a (\mu_a + \mu_s') + (2 \pi f)^2}$ in diffusion theory: here, it reaches 2.3 mm under uniform light,
0.32 mm at 0.5 /mm and 0.16 mm at 1 /mm.

## The scene

A tissue slab with two blood vessels that cross, both meshes with a Poiseuille flow of 10 mm/s on their axes, as on the
[blood flow page](lsci_tissue.md):

- a shallow vessel along x, of radius 0.1 mm, 0.05 to 0.25 mm deep;
- a deep vessel along z, of radius 0.3 mm, 0.45 to 1.05 mm deep.

The tissue has a reduced scattering coefficient of 3 /mm, so that the deep vessel's top lies 1.4 transport lengths
deep: fringes are washed out only by light that has spread, and within about a transport length light goes down and
back nearly straight and keeps them. Its capillary perfusion is Brownian motion with a diffusion coefficient of
$10^{-13}$ m²/s. The tissue and the blood scatter with $g = 0.7$ (10 and 15 /mm), rather than about 0.9: their reduced
scattering coefficients set the depths, and a less peaked phase function keeps the noise of the AC light low.

## 1. Build the scene

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 1. Build the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render the spectra under the fringes"
```

## 3. Render the spectra under the fringes

For each spatial frequency, one render holds the three phases, and a second render with new samples gives the other
factor of the products. The renders under fringes take twice the samples, as the AC light is noisier.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 3. Render the spectra under the fringes"
:end-before: "# 4. Compute the speckle variance"
```

## 4. Compute the speckle variance

The speckle variance and the intensity squared at an exposure of 5 ms, pixel by pixel: of the image under each phase,
which is what a camera measures, and of the demodulated light. Pixel by pixel, $K^2$ of the demodulated light is noisy,
and a few pixels hold rare bright samples that would dominate a sum: step 6 takes medians over many pixels.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 4. Compute the speckle variance"
:end-before: "# 5. Show the fringes"
```

(lsci-structured-fringes)=
## 5. Show the fringes

```{image} images/lsci_structured_fringes.jpg
:alt: Images under three phases of fringes at 0.5 and 1 per mm, their mean, and the speckle contrast of each
:align: center
```

What the camera sees under the fringes, and the speckle contrast of each image. The tissue washes the fringes out: as
projected, their amplitude equals the mean light; in the images, it is 0.28 of it at 0.5 /mm and 0.15 at 1 /mm, as
light that spreads sideways by a fringe's width carries light from the bright fringes into the dark ones. The mean of
the three phases is the image under uniform light (DC). The vessels barely show in it: their blood absorbs, so that they
are about 10% darker, while their motion lowers the speckle contrast far more.

The speckle contrast of each image shows both vessels, as under uniform light, and it follows the fringes: in the
tissue, 0.66 under the bright fringes and 0.57 under the dark ones at 0.5 /mm, against 0.63 under uniform light. Under a
bright fringe, much of the light came straight back from near the surface; under a dark one, it came sideways from the
bright fringes beside it, along longer paths through the perfused tissue, which decorrelate faster. The black dots are
noise of the estimate, more where there is less light. The demodulation separates the depths (step 6).

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 5. Show the fringes"
:end-before: "# 6. Show the contrast"
```

## 6. Show the contrast

```{image} images/lsci_structured.jpg
:alt: Speckle contrast under uniform light and two fringe frequencies, relative to the tissue, and the vessels' dips
:align: center
```

The top row shows what each light sees: the speckle contrast at 5 ms under uniform light and of the light that keeps
the fringes (AC), the median of $K^2$ over 9 × 9 pixels. The tissue's own contrast rises with the frequency, 0.63, 0.82
and 0.84, as the shallower light crosses less of its perfusion. The bottom row divides each map by the tissue's
contrast: the shallow vessel stays dark at every frequency, while the deep vessel's broad band fades at 0.5 /mm and has
nearly gone at 1 /mm.

| | Uniform light | 0.5 /mm | 1 /mm |
|---|---|---|---|
| Shallow vessel: K lower than the tissue's by | 78.1 ± 0.3% | 77.7 ± 0.2% | 73.7 ± 0.6% |
| Share of its dip that remains | 100% | 100 ± 1% | 94% |
| Deep vessel: K lower than the tissue's by | 20.6 ± 0.3% | 12.7 ± 0.4% | 4.5 ± 1.2% |
| Share of its dip that remains | 100% | 62 ± 2% | 22 ± 6% |

The errors are jackknife estimates over 8 bands along each vessel.

The deep vessel's dip is smaller even under uniform light: the contrast falls in proportion to the share of the
detected light that met moving blood. Most detected light stays shallow, and blood absorbs strongly (0.5 /mm at 785 nm,
25 times the tissue), so that most of the photons that reach the deep vessel are absorbed there. Its top lies 0.45 mm
deep, about the shallowest that 1 /mm fringes still remove: a vessel whose top is 0.35 mm deep keeps a third of its dip
at 1 /mm, and one whose top is 0.7 mm deep lowers the contrast by under 10% even under uniform light.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 6. Show the contrast"
:end-before: "# 7. Show flow and depth in one image"
```

## 7. Show flow and depth in one image

The figure at the top of the page. Its brightness is how much the speckle contrast drops below the tissue's under
uniform light, which plain LSCI shows, from flow at all depths. Its color is how much of that drop the 1 /mm fringes
keep: all of it for shallow flow (orange), little of it for deep flow (blue). The shallow vessel comes out orange and
the deep one blue, as in the ground truth beside them, which plain LSCI cannot tell apart. The shallow vessel's halo is
bluish too: under uniform light its effect spreads sideways with the diffuse light, and the fringes do not keep that
part.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 7. Show flow and depth in one image"
```

The full script: {download}`lsci_structured.py <code/lsci_structured.py>`. It takes about seven minutes and 4 GB of
memory.

## Limitations

- As on the [first page](#lsci-limitations): the expected contrast, without a speckle pattern, for fully developed
  speckle.
- The contrast of the AC light comes from the demodulated spectra, which a simulation gives directly. A camera
  measures the speckle of each fringe image, from which coherent SFDI estimates such depth-selective contrast.
- The AC light is noisy, with rare bright samples: its contrast is taken as medians over 9 × 9 pixels or over
  regions, and higher frequencies need more samples.
- The color of the flow and depth image is a relative depth, shallower or deeper than the fringes reach; depths in mm
  would need a calibration, such as renders of thin flowing layers at known depths.

## References

- D. J. Cuccia, F. Bevilacqua, A. J. Durkin, F. R. Ayers and B. J. Tromberg. Quantitation and mapping of tissue optical
  properties using modulated imaging. *Journal of Biomedical Optics* 14(2), 024012, 2009.
