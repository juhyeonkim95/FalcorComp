# Side-by-side visualization (online)

Falcor has two render passes that put two images next to each other in a window, both in its `DebugPasses` plugin:

- `SplitScreenPass` shows the two images over the same pixels, the first left of a divider and the second right of
  it. Drag the divider to compare the two over the same part of the image.
- `SideBySidePass` shows a half-width window of each image, next to each other: the same columns of both, for
  comparing two images in full rather than at a seam. To see each image whole, render the images twice as wide as
  the views and show their middle halves.

This tutorial uses them to compare two time gates of the Cornell box, rendered by two `TimeGatedPathTracerInline`
passes. The two passes take any two images of the same size, so the same graph compares anything else: two
tracers, two settings of one tracer (naive and antithetic sampling, two gate kernels, ...), or a tracer and its
reference.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)).

```{image} images/side_by_side_visualization.jpg
:alt: Two time gates: left and right of SplitScreenPass's divider, and both in full next to each other with SideBySidePass
:align: center
```

The images show the render graph's output, with the labels and the divider the passes draw; the window also shows
Falcor's panels on top.

## 1. Open a window and load the scene

`VIEW` picks the pass. `SideBySidePass` shows half of each image's width, so for it the window is twice as wide,
2048 x 1024, and the camera's aspect ratio follows the window. The vertical field of view does not change, so the
images get wider, not taller: their middle halves are exactly the 1024 x 1024 view of the split screen, and those are
what `SideBySidePass` shows. The two gates are box gates of width 0.1, at 16.9 and 17.337: the earlier one catches
the light front close to the laser spot on the back wall, the later one light that bounced around longer.

```{literalinclude} code/side_by_side_visualization.py
:language: python
:start-after: "# 1. Open a window and load the scene"
:end-before: "# 2. Build the two images to compare"
```

## 2. Build the two images to compare

The two tracers share the V-buffer and the laser pass. Each one has its own accumulation and tone mapper, set the
same way.

```{literalinclude} code/side_by_side_visualization.py
:language: python
:start-after: "# 2. Build the two images to compare"
:end-before: "# 3. Put them side by side"
```

## 3. Put them side by side

Both passes take the two images as `leftInput` and `rightInput`, and their `output` is shown in the window. They
draw the labels themselves, so they come after the tone mappers.

```{literalinclude} code/side_by_side_visualization.py
:language: python
:start-after: "# 3. Put them side by side"
:end-before: "# 4. Run"
```

Options:

```{list-table}
:header-rows: 1
:widths: 25 75

* - Option
  - Description
* - `splitLocation`
  - Position of the divider, as a fraction of the width. (Default: `0.5`)
* - `leftLabel`, `rightLabel`
  - Labels drawn next to the divider at the bottom of the image.
* - `showTextLabels`
  - Draw the labels. (Default: `false`)
* - `imageLeftBound`
  - `SideBySidePass` only: the first column of each image that is shown, in pixels; each side shows half the width
    from there. (Default: `0`)
```

## 4. Run

```{literalinclude} code/side_by_side_visualization.py
:language: python
:start-after: "# 4. Run"
```

In the window:

- `SplitScreenPass`: drag the divider to move it; double-click it to put it back in the middle.
- The `Compare` panel of the Render Graph window swaps the sides and turns the labels on or off; for
  `SplitScreenPass` it sets the split location, for `SideBySidePass` it slides the shown window across the images
  (`View Slider`).
- The `Early` and `Late` panels change each tracer's settings, including its gate. Changing a gate restarts that
  side's accumulation.

## Comparing other images

Any two images of the same size can go in `leftInput` and `rightInput`. For example, to compare naive and
antithetic sampling of [CW-ToF rendering](cwtof_offline.md), create two `CWToFPathTracerInline` passes that differ
only in `useAntitheticSampling`, and connect them in place of the two time-gated tracers.

The full script: {download}`side_by_side_visualization.py <code/side_by_side_visualization.py>`.
