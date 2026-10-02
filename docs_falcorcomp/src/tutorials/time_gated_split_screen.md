# Two gates side by side (online)

This tutorial shows two time-gated images of the Cornell box side by side in a window, with Falcor's
`SplitScreenPass`: two `TimeGatedPathTracerInline` passes with different gates, the earlier gate on the left of a
divider and the later one on the right. Drag the divider to compare the two over the same part of the image.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)).

```{image} images/time_gated_split_screen.jpg
:alt: The split screen: the Cornell box with the gate at 16.9 on the left and at 17.337 on the right
:width: 640px
:align: center
```

## 1. Open a window and load the scene

The two gates are box gates of width 0.1, at 16.9 and 17.337: the earlier one catches the light front close to the
laser spot on the back wall, the later one light that bounced around longer.

```{literalinclude} code/time_gated_split_screen.py
:language: python
:start-after: "# 1. Open a window and load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The two tracers share the V-buffer and the laser pass. Each one has its own accumulation and tone mapper, set the
same way, and `SplitScreenPass` takes the two tone-mapped images as `leftInput` and `rightInput`; its `output` is
shown in the window. The pass draws the labels itself, so it comes after the tone mappers.

```{literalinclude} code/time_gated_split_screen.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Run"
```

`SplitScreenPass` options:

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
  - Draw the labels.
```

## 3. Run

```{literalinclude} code/time_gated_split_screen.py
:language: python
:start-after: "# 3. Run"
```

In the window:

- Drag the divider to move it; double-click it to put it back in the middle.
- The `Split` panel of the Render Graph window sets the split location, swaps the sides and turns the labels and
  the divider arrows on or off.
- The `Early` and `Late` panels change each tracer's settings, including its gate. Changing a gate restarts that
  side's accumulation.

The same graph works with any two images of the same size: two gate kernels, two tracers, or a tracer and its
reference.

The full script: {download}`time_gated_split_screen.py <code/time_gated_split_screen.py>`.
