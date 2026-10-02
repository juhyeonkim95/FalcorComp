# Depth from CW-ToF

A CW-ToF camera measures depth from the phase of its modulated light. This page renders the four phase-shifted
measurements of the bunny scene with `CWToFPathTracerInline`, turns them into depth, and compares naive and
antithetic sampling at equal time.

```{image} images/cwtof_depth.jpg
:alt: Depth of the bunny scene from CW-ToF, and the depth errors at the wavelengths 1 and 0.02
:align: center
```

## Four phases

With the light at the camera, the path length of the direct light is twice the depth $d$. A measurement with the
modulation $\cos(2\pi\,\ell / \lambda - 2\pi\phi)$ at the phases $\phi = 0, 1/4, 1/2, 3/4$ gives $I_0, I_1, I_2,
I_3$, and the phase of the path length is

$$
\theta = \operatorname{atan2}(I_1 - I_3,\; I_0 - I_2) = \frac{2\pi\,\ell}{\lambda} \pmod{2\pi},
\qquad
d = \frac{\ell}{2}.
$$

The constant part of the light (the albedo, the distance falloff) cancels in the differences. The indirect light
does not, and it biases $\theta$: this is the multipath error of CW-ToF cameras.

```{literalinclude} code/cwtof_depth.py
:language: python
:start-after: "# 4. Capture four phase-shifted images"
:end-before: "# 6. Compare with the true depth"
```

$\theta$ gives the path length only up to multiples of $\lambda$. A real camera resolves them with a second, lower
modulation frequency; here `np.unwrap` picks, for every pixel, the multiple closest to a coarse depth, taken from the
true depth so that only the measured phase sets the depth within a quarter wavelength.

## Wavelength and precision

A short wavelength measures depth more precisely, since a given error in $\theta$ is a smaller distance, and it
suppresses the multipath error, since the indirect light cancels more. The figure compares:

- $\lambda = 1$, converged (4,096 samples per pixel per phase): the depth is off by a few millimeters, in rings that
  follow the indirect light, the largest along the edges of the box;
- $\lambda = 0.02$, 0.02 seconds per phase: the median error drops below 0.1 mm. Naive sampling (28 samples per pixel)
  leaves noise on the walls, where the light bounces between them; antithetic sampling (18 samples per pixel, with
  the barycentric shift) cancels it.

```{list-table}
:header-rows: 1
:widths: 50 25 25

* - Measurement
  - Samples per pixel
  - Median depth error
* - $\lambda = 1$, converged
  - 4,096
  - 2.7 mm
* - $\lambda = 0.02$, naive, 0.02 s per phase
  - 28
  - 0.039 mm
* - $\lambda = 0.02$, antithetic, 0.02 s per phase
  - 18
  - **0.021 mm**
```

(Scene units are taken as meters.)

## The script

The render graph is that of [CW-ToF rendering](../tutorials/cwtof_offline.md) with `computeDirect` on; the true
depth comes from the world positions of `GBufferRT`.

The full script: {download}`cwtof_depth.py <code/cwtof_depth.py>`. Run it next to the unzipped
`cornell-box-bunny-diffuse` folder; it takes about a minute.
