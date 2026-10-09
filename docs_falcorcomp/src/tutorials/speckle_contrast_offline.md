# Speckle contrast imaging (LSCI, offline)

Laser speckle contrast imaging (LSCI) images blood flow. Coherent light scattered by tissue forms a speckle pattern;
moving scatterers make it fluctuate, which blurs it over the camera's exposure and lowers its contrast
$K = \sigma_I / \langle I \rangle$. Slow flow keeps the speckle sharp, fast flow washes it out.

The LSCI camera records intensity, without a local oscillator: it is homodyne (self-beating) detection, integrated
over the exposure. This tutorial computes the speckle contrast from the Doppler spectrum that
`DopplerHistogramPathTracerInline` renders, the same spectrum as in the
[Doppler spectrum tutorial](doppler_spectrum_offline.md), with no other render pass.

It uses the scene described in [Doppler rendering](doppler_index.md).

```{image} images/speckle_contrast.jpg
:alt: Static light fraction, speckle contrast at three exposures and contrast against exposure for four pixels
:align: center
```

## Speckle contrast from the Doppler spectrum

The pass renders $S(f)$, the light that reaches a pixel at each Doppler shift $f$: the power spectrum of the optical
field, relative to the laser frequency. Without a local oscillator, the photocurrent follows the intensity, and for
fully developed speckle (a Gaussian field) its power spectrum is the autocorrelation of the optical one, as derived
for homodyne detection in Kim et al. (2025):

$$
S_i(f) = \int S(f')\, S(f' + f)\, df' .
$$

The camera integrates the intensity over the exposure $T$, which filters the fluctuations by
$\operatorname{sinc}^2(fT)$, with $\operatorname{sinc}(x) = \sin(\pi x) / (\pi x)$. The speckle contrast is then

$$
K^2(T) = \beta\, \frac{\int S_i(f)\, \operatorname{sinc}^2(fT)\, df}{I^2},
\qquad
I = \int S(f)\, df ,
$$

where $\beta$ is the coherence factor, 1 when a pixel is smaller than a speckle. This is the frequency form of the
usual model, $K^2 = \frac{2\beta}{T} \int_0^T \left(1 - \frac{\tau}{T}\right) |g_1(\tau)|^2\, d\tau$
(Bandyopadhyay et al. 2005), with $g_1$ the Fourier transform of $S$, normalized. With the spectrum in bins of
width $\Delta f$, $S_k$ the light in bin $k$:

$$
K^2(T) = \beta\, \frac{\sum_m A[m]\, \operatorname{sinc}^2(m\, \Delta f\, T)}{I^2},
\qquad
A[m] = \sum_k S_k\, S_{k+m} ,
$$

which holds for exposures well below $1 / \Delta f$.

Light from static surfaces has no shift and never decorrelates: for long exposures, $K$ tends to $\sqrt{\beta}$
times the static fraction of the light. Its beat with the moving light is the term that multi-exposure speckle models
add for static scattering (Parthasarathy et al. 2008), where static light acts as a local oscillator; the
autocorrelation contains it with nothing added.

## 1. Load the scene

```{literalinclude} code/speckle_contrast_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

As in the [Doppler spectrum tutorial](doppler_spectrum_offline.md), with a point light at the camera, which lights
the whole scene as LSCI does. The motion is slow, as blood flow is: at 785 nm, the tall box coming towards the camera
at 1 mm/s shifts light that it reflects once by $2v/\lambda \approx 2.5$ kHz. The spectrum covers -8 to 8 kHz in 1024
bins of 15.6 Hz, fine enough for exposures up to 10 ms ($1 / \Delta f = 64$ ms).

`computeDirect` is off. LSCI looks into tissue, where light scatters many times, and the speckle decorrelates
because those paths have different shifts. A single reflection off a rigidly moving surface has a single shift and
alone would not decorrelate (see [Limitations](#lsci-limitations)). One wavelength needs one channel:
`useSingleChannel`.

```{literalinclude} code/speckle_contrast_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render the spectrum twice"
```

## 3. Render the spectrum twice

$A[m]$ multiplies the spectrum by itself, and a spectrum multiplied by itself also squares its Monte Carlo noise,
which would raise the contrast. Two spectra with independent samples, one for each factor, avoid that bias. `reset()`
starts a new accumulation, and the new frames draw new samples.

```{literalinclude} code/speckle_contrast_offline.py
:language: python
:start-after: "# 3. Render the spectrum twice"
:end-before: "# 4. Compute the speckle contrast"
```

## 4. Compute the speckle contrast

$A[m]$ is computed with FFTs, a block of pixels at a time, and the sum over $m$ is a product with the matrix of
$\operatorname{sinc}^2(m\, \Delta f\, T)$ for 41 exposures from 1 µs to 10 ms. The static fraction is the light in
the bin of zero shift.

```{literalinclude} code/speckle_contrast_offline.py
:language: python
:start-after: "# 4. Compute the speckle contrast"
:end-before: "# 5. Show the contrast"
```

## 5. Show the contrast

For short exposures $K = 1$: the speckle is fully developed. It starts to decorrelate around 0.1 ms, the inverse of
the kHz spread of the shifts. All the light of the boxes is shifted, and their contrast keeps falling (0.2 at 10 ms).
The walls level off at their static fraction: 0.80 on the back wall and 0.64 on the right wall, whose light partly
came by way of the boxes.

```{literalinclude} code/speckle_contrast_offline.py
:language: python
:start-after: "# 5. Show the contrast"
```

The full script: {download}`speckle_contrast_offline.py <code/speckle_contrast_offline.py>`. It takes about 10 seconds
and 1.5 GB of memory.

(lsci-limitations)=
## Limitations

- It gives the expected contrast, not speckle images: there is no speckle pattern, so $\beta$, which depends on the
  speckle size against the pixel size, is an input.
- Fully developed (Gaussian) speckle is assumed, as in the usual LSCI model.
- Motion is rigid and deterministic: each path has one Doppler shift, and the contrast falls only through the spread
  of shifts between paths. Brownian (unordered) motion applies to the scatterers of media (see
  [blood flow in tissue](speckle_contrast_tissue.md)), not to surfaces.

## References

- R. Bandyopadhyay, A. S. Gittings, S. S. Suh, P. K. Dixon and D. J. Durian. Speckle-visibility spectroscopy: a tool
  to study time-varying dynamics. *Review of Scientific Instruments* 76, 093110, 2005.
- D. A. Boas and A. K. Dunn. Laser speckle contrast imaging in biomedical optics. *Journal of Biomedical Optics* 15(1),
  011109, 2010.
- A. B. Parthasarathy, W. J. Tom, A. Gopal, X. Zhang and A. K. Dunn. Robust flow measurement with multi-exposure
  speckle imaging. *Optics Express* 16(3), 1975–1989, 2008.
- J. Kim et al. A Monte Carlo rendering framework for simulating optical heterodyne detection. *ACM Transactions on
  Graphics* (SIGGRAPH), 2025. [Project page](https://juhyeonkim95.github.io/project-pages/ohd_rendering/)
