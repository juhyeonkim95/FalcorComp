# Transient ReSTIR (online)

In online rendering, every frame is rendered once within a fixed time budget and shown, instead of
being averaged with other frames. This tutorial moves the camera forward through a scene, by 0.005
per frame over 100 frames, and renders a 64-bin transient histogram of every frame with
`TransientHistogramPathTracerInline` and with `TransientHistogramReSTIRInline` at *equal frame
time*. Every 10th frame is compared with a reference.

`TransientHistogramReSTIRInline` uses *temporal reuse* here: every frame resamples the previous
frame's reservoirs, reprojected with motion vectors and shifted to the moved camera with the
path-length-aware shift mapping, so each bin keeps improving while the camera moves. The path
tracer starts from nothing in every frame. Temporal reuse assumes that only the camera moves; the
scene and the laser stay fixed.

The script renders one of two scenes, chosen on the command line:

- `cornell-box` (the default): the Cornell box of the other tutorials (see [ToF rendering](index.md)),
  at 256 x 256.
- `veach-ajar`: *Veach, Ajar* by Benedikt Bitterli (CC0), at 480 x 270, with the laser at the
  camera's starting position. Download {download}`veach-ajar.zip <scenes/veach-ajar.zip>` (14 MB)
  and unzip it next to the script. Its textures are converted to PNG; they are read as linear
  colors, as in the original scene.

```console
$ python transient_restir_online.py              # Cornell box
$ python transient_restir_online.py veach-ajar
```

It needs `ffmpeg` to write the videos, which show four of the 64 bins. The errors are defined as in
[the offline comparison](#transient-equal-time), over all bins. The numbers below were measured on
an NVIDIA GeForce RTX 3090 with Vulkan; frame times and the matched sample counts depend on the
GPU.

## Cornell box

```{raw} html
<div style="display: flex; flex-wrap: wrap; gap: 12px; justify-content: center; margin: 1em 0;">
  <figure style="margin: 0; flex: 1 1 300px; max-width: 480px; text-align: center;">
    <video src="../../_static/tutorials/transient_thpt_online_cornell-box.mp4" controls autoplay loop muted playsinline
           style="width: 100%;"></video>
    <figcaption>TransientHistogramPathTracerInline</figcaption>
  </figure>
  <figure style="margin: 0; flex: 1 1 300px; max-width: 480px; text-align: center;">
    <video src="../../_static/tutorials/transient_restir_online_cornell-box.mp4" controls autoplay loop muted playsinline
           style="width: 100%;"></video>
    <figcaption>TransientHistogramReSTIRInline</figcaption>
  </figure>
</div>
```

```{list-table}
:header-rows: 1
:widths: 40 15 15 15 15

* - Method
  - Samples per pixel
  - Frame time
  - Mean relMSE
  - Mean MAPE
* - `TransientHistogramPathTracerInline`
  - 534
  - 44.0 ms
  - 0.597
  - 0.683
* - `TransientHistogramReSTIRInline`
  - 32
  - 44.2 ms
  - 0.483
  - 0.437
```

At the same frame time, ReSTIR's mean relMSE over the compared frames is 19 % lower and its MAPE
36 % lower, with 17 times fewer initial samples.

## Veach, Ajar

```{raw} html
<div style="display: flex; flex-wrap: wrap; gap: 12px; justify-content: center; margin: 1em 0;">
  <figure style="margin: 0; flex: 1 1 300px; max-width: 480px; text-align: center;">
    <video src="../../_static/tutorials/transient_thpt_online_veach-ajar.mp4" controls autoplay loop muted playsinline
           style="width: 100%;"></video>
    <figcaption>TransientHistogramPathTracerInline</figcaption>
  </figure>
  <figure style="margin: 0; flex: 1 1 300px; max-width: 480px; text-align: center;">
    <video src="../../_static/tutorials/transient_restir_online_veach-ajar.mp4" controls autoplay loop muted playsinline
           style="width: 100%;"></video>
    <figcaption>TransientHistogramReSTIRInline</figcaption>
  </figure>
</div>
```

```{list-table}
:header-rows: 1
:widths: 40 15 15 15 15

* - Method
  - Samples per pixel
  - Frame time
  - Mean relMSE
  - Mean MAPE
* - `TransientHistogramPathTracerInline`
  - 277
  - 122.6 ms
  - 2.861
  - 1.133
* - `TransientHistogramReSTIRInline`
  - 32
  - 127.8 ms
  - 1.547
  - 0.403
```

The path tracer's frames stay noisy even with 277 samples per pixel. At the same frame time,
ReSTIR's mean relMSE is 46 % lower and its MAPE 64 % lower, and the room is clearly recognizable in
every frame.

## 1. Load the scene and set up the camera path

`SCENES` holds each scene's file, image size, histogram range and laser. The camera moves along
its view direction, starting from the scene's camera. The ReSTIR options
add temporal reuse to those of [the offline tutorial](transient_restir_offline.md):
`useTemporalReuse` with a `temporalHistoryLength` of 20 frames, and one round of spatial reuse,
which is cheaper per frame than the three rounds used offline.

```{literalinclude} code/transient_restir_online.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build a render graph around a tracer"
```

## 2. Build the render graph

Each frame is shown on its own, so the graph has no accumulation pass: the tracer's `histogram`
output is the frame. For ReSTIR, the motion vectors of `VBufferRT` are connected to its `mvec`
input, which it uses to find each pixel's history in the previous frame.

```{literalinclude} code/transient_restir_online.py
:language: python
:start-after: "# 2. Build a render graph around a tracer"
:end-before: "# 3. Render the sequence"
```

## 3. Render the sequence

The camera is moved before every frame. Each frame is timed with a wait for the GPU, and the first
10 frames, which include shader compilation and ReSTIR's first frames without history, are left
out of the mean frame time. Histograms are read back only when a callback asks for them, so the
timing runs measure rendering alone.

```{literalinclude} code/transient_restir_online.py
:language: python
:start-after: "# 3. Render the sequence"
:end-before: "# 4. Match the frame time"
```

## 4. Match the frame time

ReSTIR renders 32 initial samples per pixel. The path tracer starts at the same count and is then
given the sample count that fits the same frame time: its sample count is scaled by the ratio of
the frame times until they are within 5 %, with at most three adjustments.

```{literalinclude} code/transient_restir_online.py
:language: python
:start-after: "# 4. Match the frame time"
:end-before: "# 5. Render both sequences"
```

## 5. Compare with the reference

Both sequences are rendered again, this time reading every frame back, and every 10th frame is
compared with the reference histogram at the same camera position. The reference is rendered by
the path tracer with 16,384 samples per pixel, as 16 frames of 1,024 samples, so that no single
frame runs for long. If the `reference-<scene>` folder does not exist, the script renders it first
and saves it in half precision (about 250 MB for the Cornell box, 500 MB for Veach, Ajar).

```{literalinclude} code/transient_restir_online.py
:language: python
:start-after: "# 5. Render both sequences"
:end-before: "# 6. Save a video per tracer"
```

## 6. Save the videos

Every frame shows the same four bins, tone mapped the same way (Reinhard, then sRGB), labeled with
the sample count, the frame time and the mean errors, and encoded at 15 frames per second.

```{literalinclude} code/transient_restir_online.py
:language: python
:start-after: "# 6. Save a video per tracer"
```

The full script: {download}`transient_restir_online.py <code/transient_restir_online.py>`.
Including the reference, it takes about four minutes for the Cornell box and nine for Veach, Ajar.
It also saves the compared frames' errors to `errors-<scene>.csv`.
