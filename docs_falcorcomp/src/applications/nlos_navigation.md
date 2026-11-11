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
$x, z \in [0.2, 1.2]$, hides the road after the turn. The box, $0.05 \times 0.5 \times 0.2$, stands in the inner lane
($z \in [-0.05, 0.15]$) at a position $x$ that the clock sets through an animation, so that one scene serves every
position. The car's lidar is 0.2 above the road on its center line, looks 10 degrees down, and records 64 x 64 pixels
and 64 bins of 0.02 in path length, from 3.0 to 4.28. Its laser (`laserCollocated`) lights the road ahead of the car.

## The renderers

- **Path tracing**: `TransientHistogramPathTracerInline`.
- **ToF ReSTIR**: `TransientHistogramReSTIRInline` with the shift `local_tangent`: three rounds of spatial reuse, and
  bin reuse (`useBinReuse`), which also resamples the two adjacent bins of the pixel, shifted by one bin width.
- **Naive reuse**: the same pass with the shift `no`. A reused path keeps its length, so most of the paths it takes
  from a neighbor or an adjacent bin fall into another bin and are lost: more rounds and bin reuse only cost time. It
  gets one round without bin reuse, its best setting at this frame time.

The laser moves with the car, and `TransientHistogramReSTIRInline` drops its temporal history whenever the laser
changes, so neither renderer reuses paths across frames. ToF ReSTIR renders 128 samples per pixel; the script adjusts
the others to the same frame time on the drive.

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
tracing at 65,536 samples per pixel (16 frames of 4,096, summed by `accumulate`).

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
  - 0.414
  - 0.015
* - Path tracing
  - 485
  - 7.8
  - 0.455
  - 0.054
* - Naive reuse
  - 192
  - 7.6
  - 0.484
  - 0.081
* - ToF ReSTIR
  - 128
  - 7.6
  - **0.410**
  - **0.011**
```

The box stands at $x = 0.4$. On the clean training renders it has not seen, the network's mean error is 1.8 mm; on
the clean renders of the drive, its estimates sit 1.4 cm too far, at 0.414. The noise of path tracing and naive reuse
pushes their estimates 4 and 7 cm farther, in every frame of the drive. ToF ReSTIR's histograms are closer to the clean
ones: its estimates scatter around the truth, by about 1 cm. Planned around naive reuse's estimate, the car's path
runs into the box; around path tracing's, it clears the box's corner by a hair.

The video above shows the 64 bins of frame 50, from the shortest path length to the longest.

The full script: {download}`nlos_navigation.py <code/nlos_navigation.py>`. It takes about 11 minutes, most of them
for the clean training renders, which it saves to `training.npz` and reuses on the next run. It needs PyTorch
(`pip install torch`) and `ffmpeg` for the video.

## Limitations

- The network is trained on clean renders of this one scene, and it sees noisy histograms only when it estimates: the
  noise of a renderer shifts its estimate, which is what the comparison shows. Training on noisy renders would make it
  more robust, at the cost of a training set for every renderer.
- The box moves only along the road, and the car only along its center line.
