# Laser speckle contrast imaging

Laser speckle contrast imaging (LSCI) images blood flow. Coherent light scattered by tissue forms a speckle pattern;
moving scatterers make it fluctuate, which blurs it over the camera's exposure and lowers its contrast. The camera
records the intensity, without a local oscillator: the scattered light beats with itself (homodyne detection). Its
contrast follows from the Doppler spectrum that `DopplerHistogramPathTracerInline` renders (see
[Doppler rendering](../tutorials/doppler_index.md)), with no other render pass.

The first page explains the method on the Cornell box of the Doppler tutorials; the others render tissue with blood
vessels as participating media. Their scripts plot with matplotlib (`pip install matplotlib`), and the vascular
network also uses SciPy.

````{grid} 1 2 2 3
:gutter: 3

```{grid-item-card} Speckle contrast from the Doppler spectrum
:img-top: images/thumbnails/lsci_basics_thumb.jpg
:img-alt: Speckle contrast of the Cornell box with a moving and a rotating box, at a 1 ms exposure
:link: lsci_basics
:link-type: doc

Compute the speckle contrast from the Doppler spectrum, for exposures from 1 µs to 10 ms, and see the static light
keep its contrast.
```

```{grid-item-card} Blood flow in tissue
:img-top: images/thumbnails/lsci_tissue_thumb.jpg
:img-alt: Speckle contrast over a blood vessel in tissue, at a 10 ms exposure
:link: lsci_tissue
:link-type: doc

A slab of tissue with a blood vessel as participating media, the blood in a Poiseuille flow: the vessel lowers the
speckle contrast.
```

```{grid-item-card} Vascular network
:img-top: images/thumbnails/lsci_network_thumb.jpg
:img-alt: Speckle contrast of a network of blood vessels under tissue, at a 5 ms exposure
:link: lsci_network
:link-type: doc

Vessels given as grids built from their centerlines, so that they branch and curve freely, imaged by their speckle
contrast.
```
````

```{toctree}
:hidden:

lsci_basics
lsci_tissue
lsci_network
```
