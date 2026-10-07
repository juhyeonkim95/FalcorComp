# Inline path tracer (`InlinePathTracer`)

This render pass is a plain path tracer lit by the laser that the [`LaserLight`](#laser) pass publishes in the frame.
Its registered description is "Path tracer lit by the laser." It renders steady-state radiance: there are no path
lengths, gates or histograms.

Each pixel's camera paths start at its primary hit from `VBufferRT` and are extended by sampling the BSDF. Each vertex
after the primary hit is connected to the light, with one light sample and a shadow ray, and so is the primary hit
with `computeDirect`. The light depends on `isLightSourceLaser` of `LaserLight`:

- On (the default): each light sample traces the beam from the laser, along a direction in the cone of half-angle
  `laserAngle` (the beam itself when it is collimated). The first surface the beam hits, the spot, reflects the laser
  power toward the vertex through its BSDF.
- Off: a point light at the laser position, of intensity `laserPower`, that lights the half-space in front of
  `laserDirection`.

The laser pass must run first: connect it with an execution edge, `graph.add_edge("Laser", "Tracer")`. Without a
laser published in the frame, the pass warns and uses the default laser.

A path ends after `maxBounces` vertices, when the BSDF sample fails, or when its ray leaves the scene; there is no
Russian roulette. Vertices whose material has only delta lobes (a smooth mirror or smooth glass) are not connected to
the light, since such a material reflects nothing toward a sampled light; the path continues through them. A sample
whose value is infinite or NaN counts as zero.

Not implemented:

- The scene's own lights. Analytic lights, emissive surfaces and the environment map light nothing, and a path that
  hits an emissive surface adds no emission. The environment map shows only in pixels without a primary hit.
- Caustics: light that goes from the point light or the laser spot through smooth glass or off a smooth mirror before
  it reaches a surface. Connections are straight shadow rays, which glass blocks. Likewise, a laser beam lights
  nothing if the first surface it hits is a smooth mirror or glass: the beam stops there, and such a surface reflects
  nothing toward the vertex.
- The nested dielectrics and volume absorption of Falcor's `PathTracer`.

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `samplesPerPixel`
  - integer
  - Camera paths traced per pixel in each frame, all from the pixel's primary hit; the output is their mean. Must
    be at least `1`. (Default: `128`)
* - `maxBounces`
  - integer
  - Maximum number of surface vertices on a camera path, counting the primary hit. Each vertex is connected to the
    light (the primary hit only with `computeDirect`). `0` renders no light. With `computeDirect`, `maxBounces`
    $n$ renders the paths of Falcor's `PathTracer` with `maxSurfaceBounces` $n - 1$, which counts bounces after the
    primary hit. (Default: `3`)
* - `useImportanceSampling`
  - boolean
  - Importance-sample the BSDF when extending the camera path; otherwise use the material's reference sampler
    (cosine-weighted for standard materials). (Default: `true`)
* - `computeDirect`
  - boolean
  - Include the shortest path, camera -> primary hit -> light. Without it, the image holds only light that reached
    the primary hit by way of another surface. (Default: `false`)
* - `useSingleChannel`
  - boolean
  - Keep one channel of the image, chosen by `singleChannel`, and write it to all three color channels.
    (Default: `false`)
* - `singleChannel`
  - string
  - The channel kept by `useSingleChannel`: `luminance`, `red`, `green` or `blue`. (Default: `red`)
* - `useAlphaTest`
  - boolean
  - Honor alpha-tested materials when tracing the path, beam and shadow rays. The primary hits come from
    `VBufferRT`, which has its own `useAlphaTest` (on by default). (Default: `false`)
```

All of them can also be changed in the pass's panel of the Render Graph window.

All the paths of a pixel start at the same primary hit, so antialiasing comes from a jittered V-buffer (the
`samplePattern` of `VBufferRT`) and averaging frames, for example with `AccumulatePass`. Each frame draws new random
numbers.

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `vbuffer` (input)
  - Primary hits, from `VBufferRT`, at the output's size.
* - `viewW` (input, optional)
  - Primary ray directions, from `VBufferRT`. Needed for depth of field; without it, the pass uses pinhole camera
    rays and warns when the camera has an aperture.
* - `color` (output)
  - Radiance, RGBA32Float with alpha 1: the mean of the pixel's `samplesPerPixel` paths. Pixels without a primary
    hit show the scene's environment map, or black if it has none.
```

## Example

```python
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
graph = testbed.create_render_graph("InlinePathTracer")
graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0], "laserPower": [170.0, 120.0, 40.0],
})
graph.create_pass("Tracer", "InlinePathTracer", {"samplesPerPixel": 16, "maxBounces": 6, "computeDirect": True})
graph.create_pass("Accumulate", "AccumulatePass", {})
graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
graph.add_edge("VBuffer.viewW", "Tracer.viewW")
graph.add_edge("Laser", "Tracer")  # run the laser pass first
graph.add_edge("Tracer.color", "Accumulate.input")
graph.mark_output("Accumulate.output")
testbed.render_graph = graph
```

The [inline ray tracing tutorial](../../tutorials/inline_ray_tracing.md) lights the scene with a point light at the
camera and times this pass against Falcor's `PathTracer`.
