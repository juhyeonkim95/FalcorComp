# ToF rendering with ReSTIR

These tutorials render the same ToF measurements as [ToF rendering](index.md), with the ReSTIR
render passes instead of the path tracers. ReSTIR samples paths the same way, then lets every
pixel reuse the paths found by its neighbors, shifted with a path-length-aware shift mapping that
keeps their length. This pays off when few sampled paths fit the measurement, for example with a
narrow time gate, and in online rendering, where every frame is shown on its own.

They build on the [ToF rendering](index.md) tutorials, and use the same scene and render graph. Most of their scripts
save their images with Pillow 10.1 or newer (`pip install pillow`).

## Time-gated rendering

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Time-gated ReSTIR (offline)
:img-top: images/thumbnails/time_gated_restir_offline_thumb.jpg
:img-alt: Time-gated Cornell box rendered with TG ReSTIR
:link: time_gated_restir_offline
:link-type: doc

Render a narrow gate with `TimeGatedReSTIRInline`, which reuses paths across pixels, and compare
it with the path tracer at equal rendering time.
```

```{grid-item-card} Time-gated ReSTIR (online)
:img-top: images/thumbnails/time_gated_restir_online_preview.webp
:img-alt: The moving-gate sequence rendered with TG ReSTIR
:link: time_gated_restir_online
:link-type: doc

Sweep the gate over 100 frames with temporal reuse, and compare TGPT and TG ReSTIR at equal frame
time in two videos.
```
````

## Transient rendering

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Transient ReSTIR (offline)
:img-top: images/thumbnails/transient_restir_offline_thumb.jpg
:img-alt: Bins of the Cornell box's transient histogram rendered with TH ReSTIR
:link: transient_restir_offline
:link-type: doc

Render a 64-bin transient histogram with `TransientHistogramReSTIRInline`, which reuses paths
across pixels in every bin, and compare it with the path tracer at equal rendering time.
```

```{grid-item-card} Transient ReSTIR (online)
:img-top: images/thumbnails/transient_restir_online_preview.webp
:img-alt: Transient histogram bins rendered with TH ReSTIR while the camera moves
:link: transient_restir_online
:link-type: doc

Move the camera over 100 frames with temporal reuse, and compare THPT and TH ReSTIR at equal frame
time in the Cornell box and in *Veach, Ajar*.
```
````

```{toctree}
:hidden:

time_gated_restir_offline
time_gated_restir_online
transient_restir_offline
transient_restir_online
```
