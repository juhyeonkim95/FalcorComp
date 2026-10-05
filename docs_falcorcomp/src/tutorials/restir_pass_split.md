# Splitting the ReSTIR passes

The path-length-aware ReSTIR passes (`TimeGatedReSTIRInline`, `TransientHistogramReSTIRInline`) spend most of their
reuse time in the shift mapping: for every pixel and neighbor, a Newton solve moves the reconnection vertex so the
path keeps its length. This page explains how the passes split spatial (and, for transient histograms, temporal)
reuse into two kernels to make this fast, and measures the gain.

## One kernel per round

A round of spatial reuse resamples, for every pixel, its own reservoir and those of a few neighbors (5 by default),
with pairwise MIS. The straightforward kernel gives each pixel one thread, which loops over the neighbors and, for
each, replays the neighbor's path prefix in this pixel, evaluates the target function, shifts the neighbor's sample
into this pixel and this pixel's sample into the neighbor (Newton solves, with traced endpoints), and updates the
reservoir.

All of this lives in one thread: the shift's charts and Newton state, both paths, the reservoir being built. The
kernel needed the maximum of 255 registers per thread, which leaves room for only 8 warps per streaming
multiprocessor, too few to hide the latency of the rays and memory loads of the shifts. The Newton solves also
diverge: neighbors in the same warp take different numbers of iterations, or fail early.

The transient histogram pass is worse: it keeps a reservoir per histogram bin, so the same thread loops over all
bins (64 in the tutorials) and their neighbors, and its temporal reuse merged every bin's history inside the
initial sample generation kernel, the heaviest kernel of the pass.

## Two kernels per round

With `spatialReuseTwoPass` (on by default) each round runs two kernels:

1. **Pairs**: one thread per (pixel, neighbor). Each thread computes everything that pair contributes, the shift
   of the neighbor's sample into the pixel and the pairwise MIS weights of the pixel's own sample against that
   neighbor, and writes it to a 64-byte record in a buffer. A warp holds all the neighbors of a few pixels. These
   threads need 96 to 128 registers, so twice as many warps fit on the GPU, and a thread's cost is one shift
   instead of a loop over five.
2. **Resample**: one thread per pixel streams its records in neighbor order with the same random numbers as the
   single kernel, and loads a neighbor's reservoir only to fetch the sample it selects. It needs 64 registers.

The result is the same as with one kernel up to float rounding. The shift `no` (plain reconnection) always uses one
kernel: it has no shift to spread over threads, and the extra buffer traffic made it slightly slower.

For transient histograms the same split runs per chunk of histogram bins (as many bins as fit a 512 MB record
buffer), and both kernels skip empty pairs, which most bins are. Temporal reuse is split the same way
(`temporalReuseTwoPass`).

## Measure it

The script times both passes with their reuse in one kernel and in two, and reads the GPU time of each kernel from
Falcor's profiler. A run without reuse measures the initial sample generation, which is the same in both, so the
rest of each frame is the reuse. It compares the outputs of the two as well.

```{literalinclude} code/restir_pass_split.py
:language: python
:start-after: "# 2. Profile one configuration"
:end-before: "# 3. Time-gated ReSTIR"
```

The measurements use the settings of the [time-gated](time_gated_restir_offline.md) and
[transient](transient_restir_offline.md) ReSTIR tutorials: the Cornell box with the laser, 16 samples per pixel,
time-gated at 512 x 512 with three spatial rounds, transient at 256 x 256 with 64 bins and one round. Times are GPU
milliseconds per frame for the reuse only, on an NVIDIA GeForce RTX 3090 (Vulkan, clocks not locked).

**Time-gated ReSTIR, spatial reuse** (`spatialReuseTwoPass`):

```{list-table}
:header-rows: 1
:widths: 28 18 30 12 12

* - Shift mapping
  - One kernel
  - Two kernels (pairs + resample)
  - Faster by
  - Difference
* - `local_tangent`
  - 3.88 ms
  - 3.58 ms (2.81 + 0.78)
  - 1.08x
  - $10^{-8}$
* - `barycentric`
  - 4.58 ms
  - 4.09 ms (3.34 + 0.77)
  - 1.12x
  - $10^{-8}$
* - `ray_trace`
  - 11.62 ms
  - 7.41 ms (6.81 + 0.76)
  - 1.57x
  - $10^{-8}$
```

**Transient histogram ReSTIR, spatial reuse** (`spatialReuseTwoPass`):

```{list-table}
:header-rows: 1
:widths: 28 18 30 12 12

* - Shift mapping
  - One kernel
  - Two kernels (pairs + resample)
  - Faster by
  - Difference
* - `local_tangent`
  - 29.4 ms
  - 15.6 ms (12.4 + 3.5)
  - **1.88x**
  - 0
* - `barycentric`
  - 35.0 ms
  - 18.2 ms (15.0 + 3.4)
  - **1.92x**
  - 0
* - `ray_trace`
  - 87.0 ms
  - 36.4 ms (33.2 + 3.4)
  - **2.39x**
  - 0
```

The more a shift costs, the more the split helps: the ray-traced chart traces a ray at every Newton step and gains
the most. It helps far more for transient histograms, where the single kernel looped over all 64 bins in each
thread, on top of the neighbors: that loop is what the split spreads over threads, and the pass skips the empty
bins of each pair. The time-gated results differ from the single kernel only by float rounding; the transient ones
are identical.

**Transient histogram ReSTIR, temporal reuse** (`temporalReuseTwoPass`). The gain depends on the scene. On the
Cornell box with a static camera, two kernels are *slower*: the history and the current frame see the same primary
hits, so each pixel's merge is cheap and the single kernel does it within the initial sample generation, while the
split adds the records' memory traffic. In *Veach, Ajar*, with the [transient ReSTIR online](transient_restir_online.md)
tutorial's laser and a camera moving forward (480 x 270, 32 samples per pixel), every merge shifts real paths
through a complex scene, and two kernels are 2.2 to 2.9 times faster (the script runs this part if
`veach-ajar/scene-v4.pbrt` is next to it):

```{list-table}
:header-rows: 1
:widths: 30 22 24 24

* - Shift mapping
  - Cornell box, static camera
  - *Veach, Ajar*, one kernel
  - *Veach, Ajar*, two kernels
* - `local_tangent`
  - 5.3 ms → 7.4 ms (0.72x)
  - 62.6 ms
  - **21.9 ms (2.86x)**
* - `barycentric`
  - 5.6 ms → 8.0 ms (0.70x)
  - 65.0 ms
  - **24.3 ms (2.68x)**
* - `ray_trace`
  - 7.1 ms → 9.2 ms (0.77x)
  - 87.7 ms
  - **39.8 ms (2.20x)**
```

Both temporal versions give identical histograms. `temporalReuseTwoPass` is on by default, for scenes like the
second; for simple scenes rendered with a still camera, turning it off is faster.

The full script: {download}`restir_pass_split.py <code/restir_pass_split.py>`. It takes about 15 minutes.

## Other optimizations

Smaller changes, each checked to give bit-identical images:

- **Gate before shading**: a light connection's path length, and so its gate weight, is known before the
  connection is shaded. Connections outside the gate skip the visibility ray and the BSDF evaluation. This cut
  the initial sample generation of `TimeGatedReSTIRInline` by about 17% with a narrow gate.
- **Load each vertex once per shift**: the moved vertex's data is fetched once and passed along, instead of being
  reloaded by each step of the shift.
- **Stop failed shifts early**: about a quarter of ray-traced shifts fail; they now return before shading the
  shifted path.
