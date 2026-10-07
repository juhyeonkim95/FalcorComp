# Miscellaneous

Tools for looking at a scene and comparing images, shown with the time-gated path tracer. They use the same scene
as the [ToF rendering](index.md) tutorials.

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Laser visualization (offline)
:img-top: images/thumbnails/laser_visualization_thumb.jpg
:img-alt: The laser beam drawn over a time-gated Cornell box
:link: laser_visualization_offline
:link-type: doc

Draw the laser's beam over a time-gated image with `LaserPositionViewer`, from a camera that sees the beam.
```

```{grid-item-card} Side-by-side visualization (online)
:img-top: images/thumbnails/side_by_side_thumb.jpg
:img-alt: Two time gates of the Cornell box on either side of a divider
:link: side_by_side_visualization
:link-type: doc

Compare two images in a window with `SplitScreenPass` or `SideBySidePass`, here two time gates.
```
````

```{toctree}
:hidden:

laser_visualization_offline
side_by_side_visualization
```
