# ToF rendering with ellipsoidal sampling

These tutorials render with the path tracers of [ToF rendering](index.md), but sample how each
camera path reaches the laser differently. With the default `direct` sampling, every path vertex
is connected straight to the laser spot, so with a narrow gate only the few paths whose length
happens to fit contribute. *Ellipsoidal sampling* inserts a vertex whose position makes the path's
length fit the gate, so every path it samples contributes.

## Time-gated rendering

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Ellipsoidal sampling (offline)
:img-top: images/thumbnails/time_gated_ellipsoidal_thumb.jpg
:img-alt: The dragon Cornell box rendered with ellipsoidal + direct MIS sampling
:link: time_gated_ellipsoidal_offline
:link-type: doc

Compare `direct`, `ellipsoidal` and `ellipsoidal_direct_mis` sampling in
`TimeGatedPathTracerInline` at equal rendering time, on the Cornell box with a dragon.
```
````

```{toctree}
:hidden:

time_gated_ellipsoidal_offline
```
