# Online transient rendering

This tutorial shows the transient histogram from [Transient rendering](transient_offline.md) in
an interactive window. `TransientHistogramViewer` draws the histogram summed over its bins on the
left and a 4 x 4 grid of bins on the right; clicking a pixel plots its transient profile.

```{image} images/transient_online.png
:alt: The transient histogram window with a picked pixel's profile
:align: center
```

## 1. Open a window and load the scene

The window is twice as wide as the render: one half for the sum, one for the grid.

```{literalinclude} code/transient_online.py
:language: python
:start-after: "# 1. Open a window and load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`VBufferRT` and the tracer render at a fixed `SIZE` x `SIZE` (`outputSize: Fixed`) instead of
the window size. `TransientHistogramAccumulatePass` averages the tracer's per-frame histograms and
restarts when the camera moves or a setting changes, and the viewer draws the average.

```{literalinclude} code/transient_online.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Run"
```

## 3. Run

```{literalinclude} code/transient_online.py
:language: python
:start-after: "# 3. Run"
```

## Controls

- **Transient profile:** `Shift`+click (or drag) on either half picks a pixel, marked with a
  crosshair. Open *Viewer* in the *Render Graph* window to see its profile: radiance per unit
  path length over the histogram range, with the peak and the total. *Patch radius* averages
  nearby pixels to reduce noise, and *Channel* picks luminance, red, green or blue.
- **Bins:** under *Viewer*, *First bin* and *Last bin* choose the 16 bins in the grid, and *Bin
  exposure* brightens them. Under *Tracer*, *Histogram* sets the range, the number of bins and
  the filter.
- **Camera:** drag with the mouse to look around; `W`/`A`/`S`/`D` move, `Q`/`E` move down and
  up.
- **Window:** `F1` shows the help, `F2` hides the UI, `Esc` exits.

The left half only counts light whose path length lies inside the histogram range, so it is
darker than a steady-state image of the scene.

The full script: {download}`transient_online.py <code/transient_online.py>`.
