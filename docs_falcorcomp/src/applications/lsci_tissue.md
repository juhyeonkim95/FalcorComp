# Blood flow in tissue

The [first page](lsci_basics.md) computes the speckle contrast of moving surfaces.
In biomedical laser speckle contrast imaging (LSCI), the camera looks at tissue instead. Light scatters many times
under the surface, and what moves are red blood cells flowing in the vessels. This page renders that case with
participating media: a slab of tissue with a blood vessel. It computes the contrast from the Doppler spectrum as on
the first page, which explains the method.

```{image} images/lsci_tissue.jpg
:alt: Intensity, speckle contrast at three exposures, and contrast against exposure across a blood vessel in tissue
:align: center
```

## The scene

A slab of tissue, 8 × 3 × 8 mm, holds a blood vessel of radius 0.25 mm, whose axis lies 0.5 mm under the surface.
The camera looks straight down from 20 mm, at a 4 mm wide field (128 × 128 pixels of 31 µm), with a point light
next to it. Typical optical properties at 785 nm (Jacques 2013):

```{list-table}
:header-rows: 1
:widths: 20 20 20 20 20

* - Medium
  - Scattering $\mu_s$
  - Absorption $\mu_a$
  - Anisotropy $g$
  - Refractive index
* - Tissue
  - 10 /mm
  - 0.02 /mm
  - 0.9
  - 1.4
* - Blood
  - 15 /mm
  - 0.5 /mm
  - 0.9
  - 1.4
```

The blood flows along the vessel: a Poiseuille flow, 2 mm/s on the axis and zero at the wall.

Blood scatters strongly forward ($g \approx 0.98$, $\mu_s \approx 50$ /mm). This page keeps its reduced scattering
coefficient $\mu_s (1 - g)$, 1.5 /mm, with $g = 0.9$: each scattering event connects to the light through the phase
function, which is far more peaked at $g = 0.98$, and so far noisier. The vessel has the index of the tissue, as blood
nearly has; a vessel of another index would block the light connections that refract twice (see
[Participating media](#doppler-media)).

## 1. Build the scene

The script writes the scene as a `.pyscene`: the slab is a cube, and the vessel a closed cylinder whose triangles turn
counterclockwise seen from outside, so that their normals face out. The two materials hold only names and the
refractive index; the render pass gives the optical properties (step 2). Identical materials are merged when a scene
loads, and these two differ only in their names, hence `DontMergeMaterials`. The camera's near plane is 1 mm: rays
start there, and the default, 0.1 scene units (0.1 m), would start them past the tissue.

```{literalinclude} code/lsci_tissue.py
:language: python
:start-after: "# 1. Build the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`useVolumes` renders the media, `media` gives their properties per meter in full precision, and `velocities` the
flow of the blood (`flowOrigin`, `flowAxis`, `flowRadius`, `flowMaxSpeed`, in meters and m/s). Light scattered once
by blood moving at 2 mm/s is shifted by up to $2 n v / \lambda \approx 7$ kHz. The spectrum covers -16 to 16 kHz in
1024 bins of 31.25 Hz, for exposures up to 10 ms ($1 / \Delta f = 32$ ms).

```{literalinclude} code/lsci_tissue.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render the spectrum twice"
```

## 3. Render the spectrum twice

Two spectra with independent samples, so that the Monte Carlo noise of the spectrum does not raise the contrast (see
the [first page](lsci_basics.md)).

```{literalinclude} code/lsci_tissue.py
:language: python
:start-after: "# 3. Render the spectrum twice"
:end-before: "# 4. Compute the speckle contrast"
```

## 4. Compute the speckle contrast

As on the first page: the autocorrelation of the spectrum, filtered by the exposure.

```{literalinclude} code/lsci_tissue.py
:language: python
:start-after: "# 4. Compute the speckle contrast"
:end-before: "# 5. Show the contrast"
```

## 5. Show the contrast

The scene is the same along the vessel, so the curves average the contrast of a band of rows along it. For short
exposures $K = 1$ everywhere. Over the vessel, the contrast starts to fall around 0.1 ms (0.82 at 0.3 ms); at 10 ms it
is 0.29 over the axis and 0.50 over the edge, where the flow is slower and more of the light comes from static
tissue. The tissue keeps a high contrast, which falls near the vessel, where some of its light has passed through the
blood: 0.78 at 0.5 mm from the vessel's axis and 0.91 at 1.5 mm, at 10 ms. In the intensity, the vessel is only a band
11% darker, where the blood absorbs.

```{literalinclude} code/lsci_tissue.py
:language: python
:start-after: "# 5. Show the contrast"
```

The full script: {download}`lsci_tissue.py <code/lsci_tissue.py>`. It takes about a minute and
1.5 GB of memory.

## Limitations

- As on the [first page](#lsci-limitations): the expected contrast, without a speckle pattern, for fully developed
  speckle, with the coherence factor $\beta$ as an input.
- Media take the point light, not the laser beam.
- The blood moves in an ordered flow. For unordered (Brownian) motion of scatterers, give their object a `diffusion`
  coefficient in `velocities`: each scattering event then broadens a path's line (see
  [Participating media](#doppler-media)).

## References

- D. A. Boas and A. K. Dunn. Laser speckle contrast imaging in biomedical optics. *Journal of Biomedical Optics* 15(1),
  011109, 2010.
- S. L. Jacques. Optical properties of biological tissues: a review. *Physics in Medicine and Biology* 58(11),
  R37–R61, 2013.
- J. Kim et al. A Monte Carlo rendering framework for simulating optical heterodyne detection. *ACM Transactions on
  Graphics* (SIGGRAPH), 2025. [Project page](https://juhyeonkim95.github.io/project-pages/ohd_rendering/)
