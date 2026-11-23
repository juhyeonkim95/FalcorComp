# Navigating around a corner

A car with a lidar, a camera with a laser at the camera, drives toward a corner. Around it, out of sight, a box stands
in the road. Laser light that reaches the road beyond the corner bounces off the box, back to the road in front of the
car, and into the camera: the transient histogram, the light at each path length, holds where the box is. This page
trains a small network on clean renders to read the box's position from the histogram, renders the drive with path
tracing, naive reuse and ToF ReSTIR, and plans the car's path around the box from each renderer's estimate.

```{image} images/nlos_navigation_estimates.jpg
:alt: The box position estimated in every frame of the drive from each renderer's histograms
:align: center
```

## The scene and the measurement

A floor, and a building, a unit cube over $x, z \in [0.2, 1.2]$, at the corner of a road of width 0.4 that runs along
$-z$ to the origin and turns to $+x$. The box, $0.05 \times 0.5 \times 0.2$, follows the clock through an animation:
at time $t$ its center is at $(t, 0, 0)$, so one scene serves every position (and half of the box is below the floor).
The car's lidar is 0.2 above the road on its center line and looks 10 degrees down; it records 64 x 64 pixels and 64
bins of 0.02 in path length, from 3.0 to 4.28, and its laser (`laserCollocated`, a cone of 5 degrees) lights the road
ahead.

## The renderers

- **Path tracing**: `TransientHistogramPathTracerInline`, 768 samples per pixel.
- **ToF ReSTIR**: `TransientHistogramReSTIRInline`, 440 samples per pixel, with temporal reuse only: every bin of a
  pixel resamples the same bin of the previous frame, shifted with `area_adaptive` (and `avg_grad`) to the car's new
  position.
- **Naive reuse**: the same, 550 samples per pixel, with the shift `no`: a reused path keeps its vertices, so its
  length changes as the car moves and it often falls out of its bin.

The laser moves with the car. With `isSceneDynamic`, the ReSTIR pass keeps its temporal history anyway and re-lights
the reused paths with the laser of the current frame. The three renderers take about the same time per frame (see the
table below).

## 1. Build the scene

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 1. Build the scene"
:end-before: "# 2. Build a render graph for each renderer"
```

## 2. Build a render graph for each renderer

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 2. Build a render graph for each renderer"
:end-before: "# 3. Render clean histograms for training"
```

## 3. Render clean histograms for training

1024 random positions of the car ($z \in [0.5, 1]$) and of the box ($x \in [0.3, 0.6]$), each rendered with path
tracing at 65,536 samples per pixel (16 frames of 4,096, summed by `accumulate`, after a frame that the sum skips).

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 3. Render clean histograms for training"
:end-before: "# 4. Train the network"
```

## 4. Train the network

Two convolutions take the 64 bins as their input channels; the car's position and the point it looks at join before
the last two layers. Of its two outputs, the first is trained to the box's position and the second to zero.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 4. Train the network"
:end-before: "# 5. Drive"
```

## 5. Drive

The car drives 100 frames toward the corner, 0.005 per frame, with the box at $x = 0.4$. Each renderer renders the
drive in a new graph, once for its frame time and once for its histograms; the clean render repeats it with path tracing
at 65,536 samples per pixel.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 5. Drive"
:end-before: "# 6. Estimate the box's position in every frame"
```

## 6. Estimate the box's position in every frame

The plot starts at frame 20: the reuse renderers start without history.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 6. Estimate the box's position in every frame"
:end-before: "# 7. Plan the path around the box"
```

## 7. Plan the path around the box

The car plans its path with A* on a grid of the road, 1 cm per cell, from $(0, 0.51)$ to the end of the road at
$(1, 0)$. A step costs more away from the center line. The path keeps 2 cm from the walls and 1 cm from the box's
footprint, $0.05 \times 0.2$ in the inner lane ($z \in [-0.05, 0.15]$), placed where the renderer's estimate puts it
(its mean over frames 50 to 99). Shortcuts and a spline then smooth the path.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 7. Plan the path around the box"
:end-before: "# 8. Show the histograms and the planned paths"
```

## 8. Show the histograms and the planned paths

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 8. Show the histograms and the planned paths"
```

```{image} images/nlos_navigation_histograms.jpg
:alt: Eight bins of frame 50 for the clean render and the three renderers
:align: center
```

```{raw} html
<div style="margin: 1em 0; text-align: center;">
  <video src="../../_static/applications/nlos_navigation_histograms.mp4" controls autoplay loop muted playsinline
         style="width: 100%; max-width: 960px;"></video>
</div>
```

```{image} images/nlos_navigation_paths.jpg
:alt: The paths planned around the box where each renderer's estimate puts it
:align: center
:width: 60%
```

```{list-table}
:header-rows: 1
:widths: 30 15 20 35

* - Histograms from
  - spp
  - ms per frame
  - Box at (frames 50 to 99)
* - The clean render
  - 65,536
  - —
  - 0.399
* - Path tracing
  - 768
  - 10.8
  - 0.451
* - Naive reuse
  - 550
  - 11.8
  - 0.453
* - ToF ReSTIR
  - 440
  - 11.6
  - **0.415**
```

The box stands at $x = 0.4$. From the clean renders, the network finds it within 2 mm in every frame. The noise of
the other renderers shifts its estimate in the same direction, farther along the road: by 5 cm with path tracing and
naive reuse, by 1.5 cm with ToF ReSTIR, whose histograms are the closest to the clean ones (the bins above). Planned
around the estimates of path tracing and naive reuse, the car's path cuts 3 mm into the box's footprint at its true
position; planned around ToF ReSTIR's, like the clean render's, it clears the footprint.

The full script: {download}`nlos_navigation.py <code/nlos_navigation.py>`. It takes about 20 minutes, 16 of them for
the clean training renders, which it saves to `training.npz` and reuses on the next run. It needs PyTorch
(`pip install torch`), SciPy, and `ffmpeg` for the video.

## Limitations

- The network is trained on clean renders of this one scene, and sees noisy histograms only when it estimates: the
  noise of a renderer shifts its estimate, which is what the comparison shows.
- The box moves only along the road, and the car only along its center line.
- The planner assumes the box's footprint in the inner lane, $z \in [-0.05, 0.15]$; the box of the scene spans
  $z \in [-0.1, 0.1]$.
