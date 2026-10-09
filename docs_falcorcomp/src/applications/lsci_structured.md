# Structured illumination

LSCI mixes the flow at all the depths its light reaches. Structured illumination separates them. Fringes of a high
spatial frequency survive only in light that comes back from near the surface; light that goes deeper spreads sideways
and washes them out. Spatial frequency domain imaging (SFDI, Cuccia et al. 2009) uses this to measure the optical
properties of tissue at chosen depths, and its coherent version combines it with speckle contrast for flow. This page
renders the speckle contrast of the light that keeps the fringes, and finds a deep vessel fading from it as the
spatial frequency rises, while the superficial vessels stay.

```{image} images/lsci_structured.jpg
:alt: Speckle contrast under uniform light, across a deep vessel at three spatial frequencies, and against frequency
:align: center
```

## Fringes, demodulated

The point light at the camera becomes a projector of fringes along x: `patternFrequency` and `patternPhase` of
`LaserLight` scale its light by $\frac{1}{2}\left(1 + \cos(2\pi f x + \phi)\right)$ on the tissue (see
[Laser](#laser); `patternFrequency` is $f$ times the light's height, as it is set at 1 m from the light). Three
phases, $\phi_j = 0, 2\pi/3, 4\pi/3$, demodulate the images as in SFDI: their mean is the image under uniform light
(DC), and their first harmonic the light that keeps the fringes (AC) ([step 6](#lsci-structured-fringes) shows the
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
0.52 mm at 0.3 /mm and 0.26 mm at 0.6 /mm.

## The scene

The superficial vessels of the [vascular network](lsci_network.md), and a deep vessel: a cylinder of radius 0.3 mm
along z, its axis 1 mm deep, with a Poiseuille flow of 10 mm/s on its axis (a mesh, as on the
[blood flow page](lsci_tissue.md)). The tissue has a reduced scattering coefficient of 3 /mm, so that the deep vessel's
top lies two transport lengths deep: fringes are washed out only by diffuse light, and within about a transport length
light goes down and back nearly straight and keeps them. Its capillary perfusion is Brownian motion with a diffusion
coefficient of $10^{-13}$ m²/s. The tissue and the blood scatter with $g = 0.7$ (10 and 15 /mm), rather than about
0.9: their reduced scattering coefficients set the depths, and a less peaked phase function keeps the noise of the AC
light low.

## 1. Build the scene

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 1. Build the scene"
:end-before: "# 2. Build the superficial vessels"
```

## 2. Build the superficial vessels

As on the [vascular network](lsci_network.md) page.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 2. Build the superficial vessels"
:end-before: "# 3. Build the render graph"
```

## 3. Build the render graph

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 3. Build the render graph"
:end-before: "# 4. Render the spectra under the fringes"
```

## 4. Render the spectra under the fringes

For each spatial frequency, one render holds the three phases, and a second render with new samples gives the other
factor of the products.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 4. Render the spectra under the fringes"
:end-before: "# 5. Compute the speckle variance"
```

## 5. Compute the speckle variance

The speckle variance and the intensity squared at an exposure of 5 ms, pixel by pixel: of the image under each phase,
which is what a camera measures, and of the demodulated light. For the demodulated light, their ratio $K^2$ is taken
over many pixels together in step 7: pixel by pixel, the AC light is too noisy.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 5. Compute the speckle variance"
:end-before: "# 6. Show the fringes"
```

(lsci-structured-fringes)=
## 6. Show the fringes

```{image} images/lsci_structured_fringes.jpg
:alt: Images under three phases of fringes at 0.3 and 0.6 per mm, their mean, and the speckle contrast of each
:align: center
```

What the camera sees under the fringes, and the speckle contrast of each image. The tissue washes the fringes out: as
projected, their amplitude equals the mean light; in the images, it is 0.46 of it at 0.3 /mm and 0.24 at 0.6 /mm, as
light that spreads sideways by a fringe's width carries light from the bright fringes into the dark ones. The mean of
the three phases is the image under uniform light (DC). No image shows the vessels: here, their blood changes how much
light comes back too little to see, while its motion changes the speckle contrast.

The speckle contrast of each image shows the superficial vessels as under uniform light, and it follows the fringes:
in the tissue, 0.65 under the bright fringes and 0.54 under the dark ones at 0.3 /mm, against 0.62 under uniform light.
Under a bright fringe, much of the light came straight back from near the surface; under a dark one, it came sideways
from the bright fringes beside it, along longer paths through the perfused tissue, which decorrelate faster. The black
dots are noise of the estimate, more where there is less light. The demodulation separates the depths (step 7).

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 6. Show the fringes"
:end-before: "# 7. Show the contrast"
```

## 7. Show the contrast

Under uniform light, the deep vessel lowers the contrast over it to 0.91 of the tissue's, in a broad band, and the
superficial vessels to 0.40. With fringes of 0.3 /mm, the deep vessel lowers it to 0.93; at 0.6 /mm to 0.98, so that
it has nearly gone, while the superficial vessels still lower it to 0.32. The tissue's own contrast rises with the
frequency, 0.60, 0.77 and 0.83, as the shallower light crosses less of its perfusion.

```{literalinclude} code/lsci_structured.py
:language: python
:start-after: "# 7. Show the contrast"
```

The full script: {download}`lsci_structured.py <code/lsci_structured.py>`. It takes about six minutes and 4 GB of
memory.

## Limitations

- As on the [first page](#lsci-limitations): the expected contrast, without a speckle pattern, for fully developed
  speckle.
- The contrast of the AC light comes from the demodulated spectra, which a simulation gives directly. A camera
  measures the speckle of each fringe image, from which coherent SFDI estimates such depth-selective contrast.
- The AC light is noisy: its contrast is taken over regions, and higher frequencies need more samples.

## References

- D. J. Cuccia, F. Bevilacqua, A. J. Durkin, F. R. Ayers and B. J. Tromberg. Quantitation and mapping of tissue optical
  properties using modulated imaging. *Journal of Biomedical Optics* 14(2), 024012, 2009.
