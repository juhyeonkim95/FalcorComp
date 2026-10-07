# Inline ray tracing

Every falcorcomp render pass traces its rays *inline*: from a compute shader, with ray queries (`RayQuery` in
Slang, `TraceRayInline` in DirectX, `rayQueryEXT` in Vulkan). Falcor's own `PathTracer` extends its paths with the
*ray tracing pipeline* instead: a ray generation shader calls `TraceRay` for each bounce, and the driver runs a
separate hit or miss shader, chosen from a shader table, that shades the result. This page times falcorcomp's
`InlinePathTracer` against Falcor's `PathTracer` on the same light paths. On an RTX 3090, `InlinePathTracer` is 2.6
to 3.3 times faster on the three scenes below.

## The comparison

[`InlinePathTracer`](../plugin_reference/misc/InlinePathTracer.md) is falcorcomp's plain path tracer, the base of
the time-of-flight passes. Falcor's `PathTracer` is a general-purpose path tracer. The script below sets both up to
render the same light paths:

- 16 paths per pixel per frame, all starting at the pixel's primary hit from `VBufferRT` (one sample at the pixel
  center, no depth of field). Alpha testing is on.
- One light: a point light at the camera, aimed along the view, that lights the half-space in front of it. For
  `InlinePathTracer` it is `LaserLight`'s point light (`isLightSourceLaser` off, `laserCollocated` on). For
  `PathTracer` it is a Falcor `PointLight` with `openingAngle` $\pi/2$, and the scene's environment map and emissive
  lights are turned off.
- The light is sampled at every vertex but a smooth mirror or glass, the primary hit included, and a path has at most
  six surface vertices: the primary hit and up to five bounces after it. `InlinePathTracer` counts surface vertices,
  so it runs with `maxBounces` 6 and with `computeDirect` on (for the light at the primary hit). `PathTracer` counts
  bounces after the primary hit, so it runs with `maxSurfaceBounces` 5.
- No Russian roulette.

The time is the GPU time of the tracer pass (for `PathTracer`, all of its passes), the median of 200 frames, on an
NVIDIA GeForce RTX 3090 (Vulkan, clocks not locked). It is the best of three processes for the Cornell box and the
best of two for the other scenes. A repeated process can be up to about 10% slower.

```{list-table}
:header-rows: 1
:widths: 40 30 30

* - Scene
  - Inline (`InlinePathTracer`)
  - Pipeline (Falcor `PathTracer`)
* - Cornell box, 1024 x 1024
  - **10.7 ms**
  - 29.4 ms (2.8x)
* - *Veach, Ajar*, 1920 x 1080
  - **53.6 ms**
  - 178.9 ms (3.3x)
* - *Kitchen*, 1920 x 1080
  - **87.6 ms**
  - 223.6 ms (2.6x)
```

## Where the difference comes from

The ratios measure two differences at once, and this page does not separate them:

- **The ray tracing API.** Before every `TraceRay`, `PathTracer` packs the path's state into the ray payload; the
  closest-hit shader unpacks it, shades the hit and packs it again. `InlinePathTracer` runs the whole path in one
  compute thread: a ray query returns the hit to the same shader, with no payload, no shader table and no hit
  shaders to schedule, so the path's state can stay in registers. Both trace their shadow rays inline (`PathTracer`
  from its closest-hit shader).
- **The work per path.** `PathTracer` is a general-purpose path tracer. Each frame it runs a compute pass that sets
  up the paths at the primary hits, the ray tracing pass, and a compute pass that averages each pixel's 16 samples.
  With its default multiple importance sampling, it also traces one more ray from the sixth vertex to look for
  emitted light (here it finds none: emissive lights are off), and it tracks nested dielectrics and their volume
  absorption. At each vertex, `InlinePathTracer` only samples the BSDF and makes one light connection.

The more rays a path traces and the less work between them, the more the API matters. The time-of-flight passes trace
more rays per path than this plain path tracer (the beam to the laser spot, ellipsoidal connections, the traced
endpoints of shift mappings) and carry more state (path lengths, gates, reservoirs), which a pipeline version would
carry across every `TraceRay` call.

Inline ray tracing also keeps the passes simple: any compute pass can trace rays. The ReSTIR passes are made of
several compute kernels, and the shift mapping traces rays in the middle of a Newton solve (see
[Splitting the ReSTIR passes](restir_pass_split.md)); with the pipeline, each of these kernels would need its own
ray generation shader and shader table.

## Measure it on your GPU

The script times `InlinePathTracer` and Falcor's `PathTracer` (the two that ship with falcorcomp), each in its own
process, best of three:

```{literalinclude} code/inline_ray_tracing.py
:language: python
:start-after: "# 2. Time one tracer"
:end-before: "# 3. Each tracer in its own process"
```

Falcor's `PathTracer` only sees the scene's own lights, so the script adds the point light to the scene with a
small `.pyscene` file, written next to the scene, and turns off the scene's environment map and emissive lights;
`InlinePathTracer` gets the same light from `LaserLight`. Run it with the tutorials' Cornell box (the default), or
with any pbrt scene and a resolution:

```bash
python inline_ray_tracing.py                                   # Cornell box, 1024 x 1024
python inline_ray_tracing.py veach-ajar/scene-v4.pbrt 1920 1080
```

*Veach, Ajar* and *Kitchen* are by Benedikt Bitterli (pbrt-v4 versions of his
[rendering resources](https://benedikt-bitterli.me/resources/)); *Veach, Ajar* is in
{download}`veach-ajar.zip <scenes/veach-ajar.zip>`. *Kitchen* has area lights; delete their `AreaLightSource` lines
(and the `"rgb L"` line after each) before timing, since Falcor's `PathTracer` still shows the emissive surfaces that
the camera sees.

The full script: {download}`inline_ray_tracing.py <code/inline_ray_tracing.py>`.
