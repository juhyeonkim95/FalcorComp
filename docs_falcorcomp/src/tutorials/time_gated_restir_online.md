# Time-gated ReSTIR (online)

In online rendering, every frame is rendered once within a fixed time budget and shown, as in an
interactive application, instead of being averaged with other frames. This tutorial sweeps the
time gate through the Cornell box: it moves the gate center every frame, from 16.75 to 17.331 over
100 frames, with a narrow 0.01-wide gate. It renders the sweep with `TimeGatedPathTracerInline`
and with `TimeGatedReSTIRInline` at *equal frame time*, and compares every frame with a reference.

`TimeGatedReSTIRInline` uses *temporal reuse* here: every frame keeps the paths it found in earlier
frames and shifts them to the new gate with the path-length-aware shift mapping, so it keeps
improving while the gate moves. The path tracer starts from nothing in every frame.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)), renders at
1024 x 1024, and needs `ffmpeg` to write the videos.

```{raw} html
<div style="display: flex; flex-wrap: wrap; gap: 12px; justify-content: center; margin: 1em 0;">
  <figure style="margin: 0; flex: 1 1 300px; max-width: 480px; text-align: center;">
    <video src="../../_static/tutorials/time_gated_tgpt_online.mp4" controls autoplay loop muted playsinline
           style="width: 100%;"></video>
    <figcaption>TimeGatedPathTracerInline</figcaption>
  </figure>
  <figure style="margin: 0; flex: 1 1 300px; max-width: 480px; text-align: center;">
    <video src="../../_static/tutorials/time_gated_restir_online.mp4" controls autoplay loop muted playsinline
           style="width: 100%;"></video>
    <figcaption>TimeGatedReSTIRInline</figcaption>
  </figure>
</div>
```

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - Method
  - Samples per pixel
  - Frame time
  - Mean relMSE
* - `TimeGatedPathTracerInline`
  - 37
  - 38.4 ms
  - 15.1
* - `TimeGatedReSTIRInline`
  - 32
  - 40.0 ms
  - 0.465
```

At the same frame time, ReSTIR's mean error over the 100 frames is 33 times lower. Its first frame
has no history yet (relMSE 5.5); by its third frame the error is below 1. These numbers were measured
on an NVIDIA GeForce RTX 3090 with Vulkan; frame times and the matched sample count depend on the
GPU.

## 1. Load the scene and set up the sweep

The gate centers are one per frame, from the first to the last. The ReSTIR options add temporal
reuse to those of [the offline tutorial](time_gated_restir_offline.md): `useTemporalReuse` with a
`temporalHistoryLength` of 10 frames, and one round of spatial reuse with 3 neighbors, which is
cheaper per frame than the three rounds used offline.

```{literalinclude} code/time_gated_restir_online.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build a render graph around a tracer"
```

## 2. Build the render graph

Each frame is shown on its own, so the graph has no `AccumulatePass`: the tracer's `color` output
is the frame.

```{literalinclude} code/time_gated_restir_online.py
:language: python
:start-after: "# 2. Build a render graph around a tracer"
:end-before: "# 3. Render the sequence"
```

## 3. Render the sequence

`set_time_gate_info(center, center, 1)` moves the gate before every frame. For ReSTIR this keeps
the history, which temporal reuse shifts to the new gate. Each frame is timed with a wait for the
GPU, and the first 10 frames, which include shader compilation and ReSTIR's first frames without
history, are left out of the mean frame time. Images are read back only when a callback asks for
them, so the timing runs measure rendering alone.

```{literalinclude} code/time_gated_restir_online.py
:language: python
:start-after: "# 3. Render the sequence"
:end-before: "# 4. Match the frame time"
```

## 4. Match the frame time

ReSTIR renders 32 initial samples per pixel. The path tracer starts at the same count and is then
given the sample count that fits the same frame time: its sample count is scaled by the ratio of
the frame times until they are within 5 %, with at most three adjustments.

```{literalinclude} code/time_gated_restir_online.py
:language: python
:start-after: "# 4. Match the frame time"
:end-before: "# 5. Render both sequences"
```

## 5. Compare with the reference

Both sequences are rendered again, this time reading every frame back, and each frame is compared
with the reference frame of the same gate by its relative mean squared error. The reference is a
path-traced sequence with 32,768 samples per pixel per frame. If the `reference` folder does not
exist, the script renders it first, which takes roughly an hour on an RTX 3090 (about 35 s per
frame).

```{literalinclude} code/time_gated_restir_online.py
:language: python
:start-after: "# 5. Render both sequences"
:end-before: "# 6. Save a video per tracer"
```

## 6. Save the videos

Every frame is tone mapped the same way (Reinhard, then sRGB), labeled with the sample count, the
frame time and its error, and encoded at 15 frames per second.

```{literalinclude} code/time_gated_restir_online.py
:language: python
:start-after: "# 6. Save a video per tracer"
```

The full script: {download}`time_gated_restir_online.py <code/time_gated_restir_online.py>`. With
the reference in place it takes about two minutes. It also saves each frame's error to
`errors.csv`.
