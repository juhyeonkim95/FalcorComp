# Transient histogram viewer (`TransientHistogramViewer`)

This render pass shows a transient histogram in an interactive window. Its output has two halves: the left half
shows the histogram summed over its bins (or one bin), and the right half a 4 x 4 grid of 16 bins. `Shift`+click on
either half picks a pixel, and the pass's panel in the Render Graph window plots that pixel's *transient profile*,
its histogram over path length.

```{image} ../../tutorials/images/transient_online.png
:alt: The viewer's window, with the sum image on the left, 16 bins on the right and a picked pixel's profile
:align: center
```

## What it shows

With $H_i$ the input's bin $i$ (radiance per unit path length), $\Delta$ the bin width and $N$ the number of frames
summed into the input:

- **Left half**, with `leftView` `sum`: the histogram integrated over path length, $\sum_i H_i \Delta / N$: the
  radiance of the paths whose length lies in `[timeMin, timeMax)`. It is darker than a steady-state image of the
  scene, which also counts the paths outside the range. With `leftView` `bin`: bin `leftBin`, shown as a tile.
- **Right half**: 16 tiles in reading order. Tile $t = 0, \dots, 15$ shows bin
  $i = \text{firstBin} + \operatorname{round}(t\,(\text{lastBin} - \text{firstBin}) / 15)$ as
  $H_i\,(\text{timeMax} - \text{timeMin})\,2^{\text{binExposure}} / N$. At `binExposure` `0`, a tile is as bright
  as the sum image where the pixel's light is spread evenly over the range. Each tile has a one-pixel gray border
  on its left and top edges.

Each view shows the whole histogram, scaled to fit with its aspect ratio kept and centered; each output pixel
averages the histogram pixels it covers, and the area around the image is black. For one output pixel per histogram
pixel on the left, make the output (the window) `2 width x height` for a `width x height` histogram; the tiles then
show it at about a quarter of its size. The output is linear radiance: tone map it for display, e.g. with
`ToneMapper`.

The viewer reads `timeMin` and `timeMax` from the render graph, where the transient tracers publish them, and $N$,
which the tracers and `TransientHistogramAccumulatePass` publish: the number of summed frames with the path tracer's
`accumulate`, and 1 for a single frame or a mean. Without a transient tracer in the graph, the viewer takes bins of
width 1 starting at 0, for the brightness as well as the path-length labels.

## Transient profile

Hold `Shift` and click, or drag, with the left mouse button to pick the histogram pixel under the cursor, in the left
half or in any tile; `selectedPixel` holds it. The pixel gets a cyan crosshair in every view, and the *Transient
profile* group of the pass's panel plots, for each bin, the mean of the histogram over a
`(2 profileRadius + 1) x (2 profileRadius + 1)` patch around the pixel (cut at the image border), divided by $N$, in
radiance per unit path length. *Channel* picks luminance, red, green or blue. Below the plot, the panel prints the
peak (its value, its bin and the path length at the bin's center) and the profile integrated over the range (the
sum of its bins times the bin width). *Clear selection* removes the pixel. The profile is read back from the GPU
without waiting for it, so the plot lags the image by a frame or two.

The profile is shown in the UI only: there is no Python API to read it. In a script, read the histogram with
`to_numpy()` instead; pixel `(x, y)`'s histogram is `[:, y, x]`.

The panel also shows the path-length interval of every tile's bin (*Tile bins*) and, with `leftView` `bin`, of
`leftBin`, and the number of averaged frames when the input is an average (from the path tracer's `accumulate` or a
`TransientHistogramAccumulatePass`).

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `leftView`
  - string
  - The left half: `sum` (the histogram summed over its bins) or `bin` (bin `leftBin`). (Default: `sum`)
* - `leftBin`
  - integer
  - The bin on the left with `leftView` `bin`. Past the last bin, the last bin is shown. (Default: `0`)
* - `firstBin`
  - integer
  - The bin in the top-left tile. Past the last bin, the last bin is shown. (Default: `0`)
* - `lastBin`
  - integer
  - The bin in the bottom-right tile. Negative values count from the end: `-1` is the last bin for any `timeBin`.
    Below `firstBin`, every tile shows `firstBin`. (Default: `-1`)
* - `binExposure`
  - float
  - Brightens the bin views (the tiles, and the left half with `leftView` `bin`) by $2^{\text{binExposure}}$, in
    stops. Must be finite. (Default: `0`)
* - `selectedPixel`
  - integer pair
  - The histogram pixel `[x, y]` with the crosshair and the profile; `[-1, -1]` for none. `Shift`+click sets it. A
    pixel outside the histogram is cleared. (Default: `[-1, -1]`)
* - `profileRadius`
  - integer
  - The profile averages a `(2 profileRadius + 1) x (2 profileRadius + 1)` patch around `selectedPixel`. From 0 to
    16. (Default: `1`)
```

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `histogram` (input)
  - Transient histogram, `width x height x timeBin`, RGBA32Float or R32Float (shown in gray): the `histogram` output
    of a transient tracer, or the `output` of `TransientHistogramAccumulatePass`. The alpha channel is not used.
* - `overlay` (input, optional)
  - An image of the histogram's width and height with premultiplied alpha, drawn over the left half only, as
    `color * (1 - alpha) + overlay.rgb`: for example the output of a
    [`LaserPositionViewer`](../misc/LaserPositionViewer.md) without an input. An overlay of another size is ignored,
    with a warning.
* - `output` (output)
  - The views, RGBA32Float, at the size of the render graph's output (the window).
```

The viewer has no Python methods of its own.

## Example

```python
SIZE = 512  # histogram size; the window is twice as wide, one half for each view
testbed = falcor.Testbed(create_window=True, width=2 * SIZE, height=SIZE)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.scene.camera.aspectRatio = 1.0  # the histogram is square
fixed_size = {"outputSize": "Fixed", "fixedOutputSize": [SIZE, SIZE]}
graph = testbed.create_render_graph("TransientViewer")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1, **fixed_size})
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0], "laserPower": [170.0, 120.0, 40.0],
})
graph.create_pass("Tracer", "TransientHistogramPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeMin": 16.75, "timeMax": 18.03, "timeBin": 64, "accumulate": True, **fixed_size,
})
graph.create_pass("Viewer", "TransientHistogramViewer", {"firstBin": 8, "lastBin": 55, "binExposure": 1.0})
graph.create_pass("ToneMapper", "ToneMapper", {"autoExposure": False})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser", "Tracer")  # run the laser pass first
graph.add_edge("Tracer.histogram", "Viewer.histogram")
graph.add_edge("Viewer.output", "ToneMapper.src")
graph.mark_output("ToneMapper.dst")  # shown in the window
testbed.render_graph = graph
testbed.run()
```

See the [online transient rendering tutorial](../../tutorials/transient_online.md) for the full script and the
window's controls.
