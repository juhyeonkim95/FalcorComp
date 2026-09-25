# Transient histogram path tracer (`TransientHistogramPathTracerInline`)

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `samplesPerPixel`
  - integer
  - Camera paths traced per pixel in each frame. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a camera path, counting the primary hit. Each vertex
    is connected to the laser spot. (Default: `3`)
* - `samplingMethod`
  - string
  - `direct` or `tri_approx`. See [Sampling methods](#sampling-methods). (Default: `direct`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending the camera path; otherwise use the material's
    reference sampler (cosine-weighted for standard materials). (Default: `true`)
* - `computeDirect`
  - boolean
  - Include the shortest path, camera -> primary hit -> laser spot. (Default: `false`)
* - `timeMin`, `timeMax`
  - float
  - Path-length range of the histogram. Paths outside `[timeMin, timeMax)` are not recorded.
    (Default: `9`, `12`)
* - `timeBin`
  - integer
  - Number of bins $B$. (Default: `512`)
* - `timeGateMode`
  - string
  - The bin filter: `box` or `tent`; with kernel density estimation, the kernel: `box`, `tent`,
    `gaussian`, `epanechnikov` or `perlin`. See [Filters](#filters). (Default: `box`)
* - `useKernelDensityEstimation`
  - boolean
  - Spread each path over the bins with a kernel instead of a bin filter. `direct` only.
    (Default: `false`)
* - `initialWindowRatio`
  - float
  - With kernel density estimation, the kernel width of a frame's first sample, as a fraction of
    `timeMax - timeMin`, in (0, 1]. (Default: `1`)
* - `accumulate`
  - boolean
  - Sum the frames in the histogram. See [Accumulation](#accumulation). (Default: `false`)
* - `useSingleChannel`
  - boolean
  - Store one channel per bin, chosen by `singleChannel`, which quarters the histogram's memory.
    (Default: `false`)
* - `singleChannel`
  - string
  - The channel kept by `useSingleChannel`: `luminance`, `red`, `green` or `blue`.
    (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing rays. (Default: `false`)
* - `outputSize`
  - string
  - Size of the outputs: `Default` (the size of the render graph's output), `Fixed`, `Full`,
    `Half`, `Quarter` or `Double`. (Default: `Default`)
* - `fixedOutputSize`
  - integer pair
  - Output size with `outputSize` `Fixed`. (Default: `[512, 512]`)
```

This render pass renders a *transient histogram*: for every pixel, the radiance that arrives at
each total optical path length, from the laser through the scene to the camera. The range
`[timeMin, timeMax)` is split into $B$ bins (`timeBin`) of width
$\Delta = (\text{timeMax} - \text{timeMin}) / B$. With the `box` filter, bin $i$ estimates

$$
H_i = \frac{1}{\Delta} \int f(\bar{x})\, \mathbf{1}\!\left[\ell(\bar{x}) \in [t_i, t_i + \Delta)\right] \mathrm{d}\bar{x},
\qquad t_i = \text{timeMin} + i\Delta,
$$

where $f$ is the path contribution and $\ell$ the optical length (segment lengths weighted by the
index of refraction). $H_i$ is radiance per unit path length, so $\sum_i H_i \Delta$ is the
radiance of all paths in the range. Camera paths start at the primary hits from `VBufferRT` and
stop once they are longer than `timeMax`.

The histogram is a 3D texture of `width x height x timeBin` texels. From Python,
`graph.get_output("Tracer.histogram").to_numpy()` returns an array of shape
`(timeBin, height, width, 4)`, or `(timeBin, height, width)` with `useSingleChannel`. Its memory
grows with all three dimensions: at 1024 x 1024 with 512 bins, an RGBA histogram takes 8 GB.

(filters)=
## Filters

Without kernel density estimation, a path is added to the bins with a filter:

- `box`: to the bin that contains its length.
- `tent`: split between that bin and the next one, in proportion to where its length falls in the
  bin.

With `useKernelDensityEstimation`, every path is spread over all bins with the kernel chosen by
`timeGateMode`. The kernel starts at `initialWindowRatio x (timeMax - timeMin)` wide for a frame's
first sample and narrows with every further sample of the frame, then restarts in the next frame.
Paths up to `1.5 x timeMax` long can contribute through the kernel's support.

(accumulation)=
## Accumulation

Without `accumulate`, each frame writes a new histogram: the mean of that frame's
`samplesPerPixel` samples. To average frames, add a `TransientHistogramAccumulatePass` after this
pass.

With `accumulate`, the histogram is the *sum* of the frames rendered since the last reset, which
is much cheaper than a separate accumulation pass for large histograms. Divide it by the number
of frames to get the mean; `TransientHistogramViewer` does this on its own. The sum restarts when
the camera moves, a setting changes, or a script calls `reset_histogram()`.

(sampling-methods)=
## Sampling methods

- `direct`: trace camera paths and connect every vertex to the laser spot, as the time-gated path
  tracer does.
- `tri_approx`: a deterministic approximation of the paths primary hit -> one scene triangle ->
  laser spot, integrated over every triangle of the scene (a single intermediate bounce). It
  tests visibility at triangle centers and interpolates the path length linearly over each
  triangle, so it is biased; `samplesPerPixel` and `maxBounces` do not apply. It assumes a
  collimated laser.

## Laser

The laser is set on `LaserVBufferRT`, as for the
[time-gated path tracer](#laser).

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `vbuffer` (input)
  - Primary hits, from `VBufferRT`.
* - `viewW` (input, optional)
  - Primary ray directions, from `VBufferRT`.
* - `laservbuffer` (input)
  - Laser hit, from `LaserVBufferRT`.
* - `laserviewW` (input, optional)
  - Laser ray direction, from `LaserVBufferRT`.
* - `histogram` (output)
  - Transient histogram $H$, `width x height x timeBin`. RGBA32Float (the alpha channel is an
    auxiliary weight), or R32Float with `useSingleChannel`.
* - `color` (output)
  - Radiance of the frame, summed over all path lengths the camera paths reach, RGBA32Float.
```

The pass also publishes the histogram's range and the number of summed frames to the render
graph, so a `TransientHistogramViewer` downstream labels the path lengths and averages the frames
without extra settings.

## Example

```python
graph.create_pass("Tracer", "TransientHistogramPathTracerInline", {
    "samplesPerPixel": 16, "maxBounces": 6,
    "timeMin": 16.75, "timeMax": 18.03, "timeBin": 64,
})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser.vbuffer", "Tracer.laservbuffer")
graph.add_edge("Laser.viewW", "Tracer.laserviewW")
graph.create_pass("Accumulate", "TransientHistogramAccumulatePass", {})
graph.add_edge("Tracer.histogram", "Accumulate.input")
graph.mark_output("Accumulate.output")
```

See the [transient rendering tutorial](../../tutorials/transient_offline.md) for a complete
script.
