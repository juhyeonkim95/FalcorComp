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

```{grid-item-card} Two gates side by side (online)
:img-top: images/thumbnails/time_gated_split_screen_thumb.jpg
:img-alt: Two time gates of the Cornell box on either side of a divider
:link: time_gated_split_screen
:link-type: doc

Show two time gates side by side in a window with `SplitScreenPass`, and drag the divider between them.
```
````

```{toctree}
:hidden:

laser_visualization_offline
time_gated_split_screen
```
