# Vascular network

The [previous page](lsci_tissue.md) models one vessel as a mesh. LSCI images of tissue, the cortex for
example, show networks of vessels that branch and curve, of many sizes, which meshes do not handle well: each vessel
would be a closed mesh, and branches would overlap. Here, the vessels are given as grids instead: the fraction of blood
in each cell under the surface, and the blood's velocity. This page builds the grids from the vessels' centerlines,
renders the tissue with them, and computes the speckle contrast as in the
[first page](lsci_basics.md). Besides matplotlib, it uses SciPy (`pip install scipy`).

```{image} images/lsci_network.jpg
:alt: Vessels under tissue, the intensity, the speckle contrast at 1 and 5 ms, and contrast against exposure
:align: center
```

## Vessels as grids

`set_vessels` puts blood into a medium, here the tissue, from numpy arrays: the blood fraction, shape (nz, ny, nx),
and the blood's velocity in m/s, shape (nz, ny, nx, 3), at the centers of the cells of a box. Between the cells, they
are interpolated. The medium's coefficients there mix its own with the blood's by the fraction. Where a path scatters,
the scatterer is blood or tissue, in proportion to how much each scatters, and blood moves with the velocity of the
grid; see [Participating media](#doppler-media).

The network has a main vessel of radius 60 to 50 µm, two branches of 35 to 25 µm and four small vessels of 20 to
15 µm, each with its axis 20 µm under the surface plus its radius. Blood flows faster in wider vessels: on the axis,
2 mm/s at a radius of 20 µm, 6 mm/s in the main vessel. The tissue and the blood have the optical properties of the
previous page. The tissue's capillaries perfuse it, here as Brownian motion of its scatterers, with a diffusion
coefficient of $5 \times 10^{-13}$ m²/s. The camera looks at a 3 mm wide field, in 256 × 256 pixels of 12 µm.

## 1. Build the scene

The tissue slab of the previous page, without a vessel mesh.

```{literalinclude} code/lsci_network.py
:language: python
:start-after: "# 1. Build the scene"
:end-before: "# 2. Build the vessel grids"
```

## 2. Build the vessel grids

Each vessel is a smooth curve through a few points, with a radius at each. `vessel_grids` finds, for each cell, the
vessel whose wall it lies deepest within, using a k-d tree over points along the curves. The blood fraction falls from
1 to 0 over one cell across the wall, and the velocity follows the curve, in a Poiseuille profile. The grid covers the
top 0.2 mm of the tissue under the field in cells of 10 µm (360 × 20 × 360).

A vessel map segmented from an image works the same way: thin it to centerlines (for example with
`skimage.morphology.skeletonize`), take the radii from its distance transform, and place the centerlines under the
surface.

```{literalinclude} code/lsci_network.py
:language: python
:start-after: "# 2. Build the vessel grids"
:end-before: "# 3. Build the render graph"
```

## 3. Build the render graph

As on the previous page, with the vessels given by `set_vessels`. Blood at 6 mm/s shifts light by up to about
20 kHz, so the spectrum covers -32 to 32 kHz in 1024 bins of 62.5 Hz, and the exposures go up to 5 ms
($1 / \Delta f = 16$ ms).

```{literalinclude} code/lsci_network.py
:language: python
:start-after: "# 3. Build the render graph"
:end-before: "# 4. Render the spectrum twice"
```

## 4. Render the spectrum twice

```{literalinclude} code/lsci_network.py
:language: python
:start-after: "# 4. Render the spectrum twice"
:end-before: "# 5. Compute the speckle contrast"
```

## 5. Compute the speckle contrast

```{literalinclude} code/lsci_network.py
:language: python
:start-after: "# 5. Compute the speckle contrast"
:end-before: "# 6. Show the contrast"
```

## 6. Show the contrast

The curves average the contrast over the pixels near the axis of each kind of vessel, and over the tissue more than
0.2 mm from any vessel. The whole network shows in the contrast, the faster vessels darker: at 5 ms, $K$ is 0.23 over
the main vessel, 0.34 over the branches, 0.43 over the small vessels and 0.51 over the tissue, whose perfusion lowers
its contrast too. In the intensity, the main vessel is only 4% darker than the tissue, and the small ones do not show.

```{literalinclude} code/lsci_network.py
:language: python
:start-after: "# 6. Show the contrast"
```

The full script: {download}`lsci_network.py <code/lsci_network.py>`. It takes about two and a
half minutes and 2.5 GB of memory.

## Limitations

- As on the [first page](#lsci-limitations): the expected contrast, without a speckle pattern, for fully developed
  speckle, with the coherence factor $\beta$ as an input.
- The grid resolves vessels a few cells wide or more; its cells are 10 µm here.
- One medium holds vessels. Free flights in it are delta tracked against the larger of the tissue's and the blood's
  extinction, so blood that scatters far more than the tissue makes the rendering slower.
- The perfusion of the tissue is modeled as Brownian motion of all its scatterers, and the blood as an ordered flow.
