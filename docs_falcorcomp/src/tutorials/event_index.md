# Event camera rendering

An event camera reports, at each pixel, when the brightness $L = \log(I_\epsilon + I)$ changes by more than a
threshold, instead of capturing frames. Simulating one with path tracing needs the change of each pixel between
frames, which is much smaller than the image and so drowns in Monte Carlo noise unless the frames are rendered with
correlated random numbers and the difference is denoised.

| Method | Render passes |
|---|---|
| **Frame difference** of independent or correlated renders | `PathTracer` × 2, `EventDifference` |
| **EventSVGF**: the correlated difference, denoised | `PathTracer` × 2, `EventSVGF` |
| **Events** from the brightness change | `EventGenerator` |

See [Event camera rendering](../plugin_reference/event.md) for how correlated sampling works.

- **Scene:** the Cornell box with its area light, {download}`scene-v4.pbrt <scenes/cornell-box/scene-v4.pbrt>`
  ({download}`LICENSE.txt <scenes/cornell-box/LICENSE.txt>`), saved as `cornell-box/scene-v4.pbrt`. It differs from
  the other tutorials' `scene-v4-nolight.pbrt` only by the light.
- **Extra package:** the script plots with matplotlib (`pip install matplotlib`).

## Tutorials

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Event camera (offline)
:img-top: images/thumbnails/event_camera_thumb.jpg
:img-alt: Intensity change of the Cornell box rendered with EventSVGF while the camera moves forward
:link: event_camera_offline
:link-type: doc

Move the camera through the Cornell box and compare the brightness change and the events of path tracing,
correlated path tracing and EventSVGF with a reference.
```
````

```{toctree}
:hidden:

event_camera_offline
```
