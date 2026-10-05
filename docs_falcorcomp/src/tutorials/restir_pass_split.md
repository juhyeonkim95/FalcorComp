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

The script renders the time-gated ReSTIR tutorial's Cornell box at 512 x 512 with three rounds of spatial reuse,
once with one kernel and once with two, and reads the GPU time of each kernel from Falcor's profiler. A run without
spatial reuse measures the initial sample generation, which is the same in both, so the rest of each frame is the
spatial reuse:

```{literalinclude} code/restir_pass_split.py
:language: python
:start-after: "# 2. Profile one configuration"
```

```{list-table}
:header-rows: 1
:widths: 24 19 19 19 19

* - Shift mapping
  - One kernel
  - Two kernels (pairs + resample)
  - Faster by
  - Image difference
* - `local_tangent`
  - 3.88 ms
  - 3.58 ms (2.79 + 0.77)
  - 1.09x
  - $10^{-8}$
* - `barycentric`
  - 4.60 ms
  - 4.09 ms (3.31 + 0.77)
  - 1.13x
  - $10^{-8}$
* - `ray_trace`
  - 11.48 ms
  - 7.50 ms (6.84 + 0.76)
  - 1.53x
  - $10^{-8}$
```

Times are per frame for three rounds, on an NVIDIA GeForce RTX 3090 (Vulkan, clocks not locked). The more a shift
costs, the more the split helps: the ray-traced chart traces a ray at every Newton step, and gains the most. The
gain is larger for transient histograms, where the single kernel looped over every bin: on the Cornell box at
256 x 256 with 64 bins and one round of local-tangent spatial reuse, the frame went from 52.3 to 36.1 ms
(clocks locked at 1395 MHz), and two-pass temporal reuse cut the temporal merge of *Veach, Ajar* at 480 x 270 from
86 to 36 ms.

The full script: {download}`restir_pass_split.py <code/restir_pass_split.py>`.

## Other optimizations

Smaller changes, each checked to give bit-identical images:

- **Gate before shading**: a light connection's path length, and so its gate weight, is known before the
  connection is shaded. Connections outside the gate skip the visibility ray and the BSDF evaluation. This cut
  the initial sample generation of `TimeGatedReSTIRInline` by about 17% with a narrow gate.
- **Load each vertex once per shift**: the moved vertex's data is fetched once and passed along, instead of being
  reloaded by each step of the shift.
- **Stop failed shifts early**: about a quarter of ray-traced shifts fail; they now return before shading the
  shifted path.
