# Time of flight

These applications reconstruct the scene from time-of-flight measurements rendered with `TimeGatedPathTracerInline`
and `TimeGatedReSTIRInline` (see [ToF rendering](../tutorials/index.md), [ToF rendering with
ReSTIR](../tutorials/restir_index.md) and [Ellipsoidal sampling](../tutorials/ellipsoidal_index.md)).

Download and unzip the scene next to the script:

- {download}`nlos-dragon.zip <scenes/nlos-dragon.zip>` (1.8 MB): a relay wall and the Stanford dragon, pressed flat,
  out of the camera's view.

The light source is the laser of the render passes, so the scene has none. The script needs matplotlib. The numbers
were measured on an NVIDIA GeForce RTX 3090 with Vulkan.

````{grid} 1 2 2 3
:gutter: 3

```{grid-item-card} Hidden objects from time-gated images
:img-top: images/thumbnails/nlos_reconstruction_thumb.jpg
:img-alt: A dragon out of the camera's view, reconstructed from time-gated images of a relay wall
:link: nlos_reconstruction
:link-type: doc

Scan a hidden dragon voxel by voxel through a relay wall, with four time-gated renderers at equal frame time.
```
````

```{toctree}
:hidden:

nlos_reconstruction
```
