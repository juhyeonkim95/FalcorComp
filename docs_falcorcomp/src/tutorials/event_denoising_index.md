# Event rendering with denoising

These tutorials render event cameras as in [Event camera rendering](event_index.md), but at a few samples per pixel
per frame, as long sequences need. Even with correlated sampling, the difference then has rare large errors, and
denoising is needed. Denoising each frame's image (OptiX, SVGF) leaves residual noise that changes from frame to
frame, which the difference amplifies into false events. EventSVGF denoises the difference itself (Kim et al.,
EGSR 2026).

| Method | Render passes |
|---|---|
| **Primal denoising**: denoise each image, then take the difference | `PathTracer`, `OptixDenoiser` or `SVGFPass`, `EventDifference` |
| **EventSVGF**: denoise the correlated difference | `PathTracer` × 2, `EventSVGF` |

The tutorials use the scene and the packages of [Event camera rendering](event_index.md). `OptixDenoiser` needs a
build with OptiX (CUDA).

## Tutorials

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Event rendering with denoising (offline)
:img-top: images/thumbnails/event_denoising_thumb.jpg
:img-alt: Intensity change of the Cornell box rendered with EventSVGF at 1 + 1 samples per pixel
:link: event_denoising_offline
:link-type: doc

Compare path tracing, correlated path tracing, the OptiX denoiser, SVGF and EventSVGF at about equal time per
frame, against a reference.
```
````

```{toctree}
:hidden:

event_denoising_offline
```
