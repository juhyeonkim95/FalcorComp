# Time-gated ReSTIR side by side (online)

This tutorial shows the moving-gate comparison from
[Time-gated ReSTIR (online)](time_gated_restir_online.md) live in a window:
`TimeGatedPathTracerInline` on the left and `TimeGatedReSTIRInline` on the right of a split screen,
while the gate sweeps through the Cornell box. The split screen is Falcor's `SplitScreenPass`: it
shows one input left of a divider and another right of it, and the divider can be dragged across
the image.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)).

```{note}
`SplitScreenPass` is in Falcor's `DebugPasses` plugin, which the falcorcomp wheel (0.1.3) does not
include yet. Run this tutorial with a Falcor build from source.
```

```{image} images/time_gated_restir_split_screen.png
:alt: The split-screen window, with the path tracer on the left and ReSTIR on the right
:width: 640px
:align: center
```

The render graph's output over one sweep of the gate (100 frames):

```{raw} html
<video src="../../_static/tutorials/time_gated_restir_split_screen.mp4" controls autoplay loop muted playsinline
       style="display: block; width: 100%; max-width: 640px; margin: 1em auto;"></video>
```

## 1. Open a window and load the scene

The gate settings make both tracers sweep the gate by themselves: `shiftGate` moves the gate to the
next of `timeBin` centers after every frame and starts again after the last one. The centers are
the 100 of the [online tutorial](time_gated_restir_online.md). Both tracers start at the first
center and move together.

Both tracers render every frame, so they should cost about the same for a fair comparison: the
path tracer gets 37 samples per pixel against ReSTIR's 32, the sample counts that matched their
frame times in the online tutorial on an RTX 3090. On another GPU, use that tutorial's script to
find the matching count.

```{literalinclude} code/time_gated_restir_split_screen.py
:language: python
:start-after: "# 1. Open a window and load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The two tracers share the V-buffer and the laser pass. Each side is tone mapped the same way, and
`SplitScreenPass` takes the two images as `leftInput` and `rightInput`; its `output` is shown in the
window. The pass draws the labels itself, so it comes after the tone mappers. ReSTIR also gets the
V-buffer's motion vectors, so that its temporal reuse follows the camera when you move it.

```{literalinclude} code/time_gated_restir_split_screen.py
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

```{literalinclude} code/time_gated_restir_split_screen.py
:language: python
:start-after: "# 3. Run"
```

In the window:

- Drag the divider to move it; double-click it to put it back in the middle.
- The `Split` panel of the Render Graph window sets the split location, swaps the sides and turns
  the labels and the divider arrows on or off.
- The `PT` and `ReSTIR` panels change each tracer's settings, including the gate. Turn off
  `Shift gate` in both to hold the gate still.
- The frame rate in the top left is for both tracers together: about 12 frames per second at
  1024 x 1024 on an RTX 3090.

The full script:
{download}`time_gated_restir_split_screen.py <code/time_gated_restir_split_screen.py>`.
