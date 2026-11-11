# Time of flight

These applications reconstruct the scene from time-of-flight measurements: time-gated images, rendered with
`TimeGatedPathTracerInline` and `TimeGatedReSTIRInline`, and transient histograms, rendered with
`TransientHistogramPathTracerInline` and `TransientHistogramReSTIRInline` (see [ToF rendering](../tutorials/index.md),
[ToF rendering with ReSTIR](../tutorials/restir_index.md) and [Ellipsoidal sampling](../tutorials/ellipsoidal_index.md)).

[Hidden objects from time-gated images](nlos_reconstruction.md) needs its scene; download and unzip it next to the
script:

- {download}`nlos-dragon.zip <scenes/nlos-dragon.zip>` (1.8 MB): a relay wall and the Stanford dragon, pressed flat,
  out of the camera's view.

[Navigating around a corner](nlos_navigation.md) builds its scene, and needs PyTorch (`pip install torch`). The light
source is the laser of the render passes, so the scenes have none. The scripts need matplotlib. The numbers were
measured on an NVIDIA GeForce RTX 3090 with Vulkan.

````{grid} 1 2 2 3
:gutter: 3

```{grid-item-card} Hidden objects from time-gated images
:img-top: images/thumbnails/nlos_reconstruction_thumb.jpg
:img-alt: A dragon out of the camera's view, reconstructed from time-gated images of a relay wall
:link: nlos_reconstruction
:link-type: doc

Scan a hidden dragon voxel by voxel through a relay wall, with four time-gated renderers at equal frame time.
```

```{grid-item-card} Navigating around a corner
:img-top: images/thumbnails/nlos_navigation_thumb.jpg
:img-alt: A path planned around a box hidden beyond a corner
:link: nlos_navigation
:link-type: doc

Estimate where a hidden box stands from transient histograms, with a small network, and plan a path around it.
```
````

```{toctree}
:hidden:

nlos_reconstruction
nlos_navigation
```
