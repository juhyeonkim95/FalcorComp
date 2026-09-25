# ToF rendering with ReSTIR

These tutorials render the same ToF measurements as [ToF rendering](index.md), with the ReSTIR
render passes instead of the path tracers. ReSTIR samples paths the same way, then lets every
pixel reuse the paths found by its neighbors, shifted with a path-length-aware shift mapping that
keeps their length. This pays off when few sampled paths fit the measurement, for example with a
narrow time gate.

They build on the [ToF rendering](index.md) tutorials, and use the same scene and render graph.

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
````

```{toctree}
:hidden:

time_gated_restir_offline
```
