# Navigating around a corner

A car with a lidar, a camera with a laser at the camera, drives toward a corner. Around it, out of sight, a box stands
in the road. Laser light that reaches the road beyond the corner bounces off the box, back to the road in front of the
car, and into the camera: the transient histogram, the light at each path length, holds where the box is. This page
trains a small network on clean renders to read the box's position from the histogram, renders the drive with three
renderers at equal frame time, and plans the car's path around the box from each renderer's estimate.

```{image} images/nlos_navigation.jpg
:alt: Transient histogram bins of each renderer, the estimated box position along the drive, and the planned paths
:align: center
```

```{raw} html
<div style="margin: 1em 0; text-align: center;">
  <video src="../../_static/applications/nlos_navigation_histograms.mp4" controls autoplay loop muted playsinline
         style="width: 100%; max-width: 960px;"></video>
</div>
```

## The scene and the measurement

A road of width 0.4 runs along $-z$ to a corner at the origin and turns to $+x$. A building, a unit cube over
$x, z \in [0.2, 1.2]$, hides the road after the turn. The box, $0.05 \times 0.5 \times 0.2$, is centered at $(x, 0, 0)$,
across the road's center line and half below the road, at a position $x$ that the clock sets through an animation, so
that one scene serves every position. The car's lidar is 0.2 above the road on its center line, looks 10 degrees down, and records 64 x 64 pixels
and 64 bins of 0.02 in path length, from 3.0 to 4.28. Its laser (`laserCollocated`) lights the road ahead of the car.

## The renderers

- **Path tracing**: `TransientHistogramPathTracerInline`.
- **ToF ReSTIR**: `TransientHistogramReSTIRInline` with temporal reuse only: every bin of a pixel resamples the same
  bin of the previous frame, shifted with `area_adaptive` (and `avg_grad`) to the car's new position.
- **Naive reuse**: the same, with the shift `no`: a reused path keeps its vertices, so its length changes as the car
  moves and it often falls out of its bin.

The laser moves with the car. With `isSceneDynamic`, the ReSTIR pass keeps its temporal history anyway and re-lights
the reused paths with the laser of the current frame. ToF ReSTIR renders 440 samples per pixel; path tracing and naive
reuse start from 768 and 550, and the script adjusts them to the same frame time on the drive.

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

512 random positions of the car ($z \in [0.5, 1]$) and of the box ($x \in [0.3, 0.6]$), each rendered with path
tracing at 65,536 samples per pixel (16 frames of 4,096, summed by `accumulate`, after a frame that the sum skips).

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 3. Render clean histograms for training"
:end-before: "# 4. Train the network"
```

## 4. Train the network

Two convolutions take the 64 bins as their input channels; the car's position joins before the last two layers.
448 histograms train the network, and the other 64 test it.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 4. Train the network"
:end-before: "# 5. Drive"
```

## 5. Drive

The car drives 100 frames toward the corner, 0.005 per frame, with the box at $x = 0.4$. Each renderer renders the
drive in a new graph; the clean render repeats it with path tracing at 65,536 samples per pixel.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 5. Drive"
:end-before: "# 6. Estimate the box's position in every frame"
```

## 6. Estimate the box's position in every frame

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 6. Estimate the box's position in every frame"
:end-before: "# 7. Plan the path around the box"
```

## 7. Plan the path around the box

The car plans its path with A* on a grid of the road, 1 cm per cell, around the box where the renderer's estimate
puts it (its mean over the last 50 frames), keeping 3 cm from the box and the walls.

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 7. Plan the path around the box"
:end-before: "# 8. Show the histograms, the estimates and the planned paths"
```

## 8. Show the histograms, the estimates and the planned paths

```{literalinclude} code/nlos_navigation.py
:language: python
:start-after: "# 8. Show the histograms, the estimates and the planned paths"
```

```{list-table}
:header-rows: 1
:widths: 28 12 16 22 22

* - Histograms from
  - spp
  - ms per frame
  - Box at (last 50 frames)
  - Mean error (all frames)
* - The clean render
  - 65,536
  - —
  - 0.399
  - 0.0015
* - Path tracing
  - 831
  - 11.8
  - 0.416
  - 0.018
* - Naive reuse
  - 550
  - 12.0
  - 0.414
  - 0.017
* - ToF ReSTIR
  - 440
  - 11.7
  - **0.403**
  - **0.0072**
```

The box stands at $x = 0.4$. On the clean training renders it has not seen, the network's mean error is 1.6 mm, and on
the clean renders of the drive 1.5 mm. The noise of the other renderers shifts its estimates from frame to frame. ToF
ReSTIR's histograms are the closest to the clean ones (the bins above), and its estimates the closest to the box:
7 mm off on average, against 17 mm for naive reuse and 18 mm for path tracing. The reuse renderers start without
history, so their first frames are noisier (ToF ReSTIR's first estimate is 0.46). Every planned path clears the box:
the planner keeps 3 cm from the box where the renderer puts it, more than these errors.

The video above shows the 64 bins of frame 50, from the shortest path length to the longest.

The full script: {download}`nlos_navigation.py <code/nlos_navigation.py>`. It takes about 12 minutes, most of them
for the clean training renders, which it saves to `training.npz` and reuses on the next run. It needs PyTorch
(`pip install torch`) and `ffmpeg` for the video.

## Limitations

- The network is trained on clean renders of this one scene, and it sees noisy histograms only when it estimates: the
  noise of a renderer shifts its estimate, which is what the comparison shows. Training on noisy renders would make it
  more robust, at the cost of a training set for every renderer.
- The box moves only along the road, and the car only along its center line.
