# Modulated light

These applications reconstruct the scene from modulated-light measurements rendered with `CWToFPathTracerInline`
and `StructuredLightPathTracerInline` (see [Modulated light](../tutorials/modulated_index.md)). They render the full
measurement, direct and indirect light, as a real sensor sees it, and compare naive and
[antithetic sampling](../tutorials/modulated_antithetic_index.md) at equal rendering time.

They use two Cornell-box scenes with objects from the Stanford 3D Scanning Repository. Download and unzip them next
to the scripts:

- {download}`cornell-box-bunny-diffuse.zip <scenes/cornell-box-bunny-diffuse.zip>`: a diffuse bunny, for depth.
- {download}`cornell-box-separation.zip <scenes/cornell-box-separation.zip>` (3.6 MB): a glass dragon, a diffuse
  armadillo and a rough metal bunny, for the separation.

The light sources are lights of the render passes, so the scenes have none. The scripts need matplotlib. The numbers
were measured on an NVIDIA GeForce RTX 3090 with Vulkan.

````{grid} 1 2 2 3
:gutter: 3

```{grid-item-card} Depth from CW-ToF
:img-top: images/thumbnails/cwtof_depth_thumb.jpg
:img-alt: Depth of the bunny scene reconstructed from CW-ToF
:link: cwtof_depth
:link-type: doc

Four phase-shifted measurements, phase to depth, and `np.unwrap`.
```

```{grid-item-card} Depth from structured light
:img-top: images/thumbnails/structured_light_depth_thumb.jpg
:img-alt: Depth of the bunny scene reconstructed from structured light
:link: structured_light_depth
:link-type: doc

Gray and XOR codes, decoded to projector columns and triangulated.
```

```{grid-item-card} Direct and global separation
:img-top: images/thumbnails/direct_global_separation_thumb.jpg
:img-alt: Global light of the separation scene
:link: direct_global_separation
:link-type: doc

Separate the direct and the global light with shifted checkerboards (Nayar et al. 2006).
```
````

```{toctree}
:hidden:

cwtof_depth
structured_light_depth
direct_global_separation
```
