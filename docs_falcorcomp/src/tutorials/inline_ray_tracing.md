# Inline ray tracing

Every falcorcomp render pass traces its rays *inline*: from a compute shader, with ray queries (`RayQuery` in
Slang, `TraceRayInline` in DirectX, `rayQueryEXT` in Vulkan). Falcor's own `PathTracer` uses the *ray tracing
pipeline* instead, where a ray generation shader calls `TraceRay` and the driver runs separate hit and miss shaders
for each ray. This page compares the two on the same paths and shows why the inline passes are 2 to 6 times faster.

## The comparison

`InlinePathTracer` is falcorcomp's plain path tracer, the base of the time-of-flight passes. For this comparison we
also wrote its ray tracing pipeline version: the same paths, light samples and random numbers, with every ray (the
scatter rays and the light's visibility rays) traced with `TraceRay` from a ray generation shader, and the shading
left in the ray generation shader as in the inline loop. Its images agree with the inline ones to float rounding
(relative L1 difference about $10^{-5}$). This pipeline version is not part of falcorcomp. Falcor's `PathTracer`,
also pipeline-based, renders the same image but does more work per path (it is a general-purpose path tracer).

All three render 16 samples per pixel per frame with 6 bounces, a point light at the camera and no Russian
roulette; the time is the GPU time of the tracer pass, the median of 200 frames, best of three processes, on an
NVIDIA GeForce RTX 3090 (Vulkan).

```{list-table}
:header-rows: 1
:widths: 31 23 23 23

* - Scene
  - Inline (`InlinePathTracer`)
  - Pipeline, same paths
  - Falcor `PathTracer`
* - Cornell box, 1024 x 1024
  - **10.7 ms**
  - 20.9 ms (2.0x)
  - 29.3 ms (2.7x)
* - *Veach, Ajar*, 1920 x 1080
  - **53.9 ms**
  - 319.7 ms (5.9x)
  - 190.8 ms (3.5x)
* - *Kitchen*, 1920 x 1080
  - **87.3 ms**
  - 301.7 ms (3.5x)
  - 229.0 ms (2.6x)
```

## Why inline is faster here

A falcorcomp path vertex needs little shading: one material evaluation, a light connection, a few scalars such as
the path length and the gate. With the pipeline, each `TraceRay` hands the ray to the driver, which schedules the
hit shaders found in the shader table and returns their result through the ray payload; the ray generation
shader's live state (the path, its throughput and length, the random state) is spilled around every call. With
inline ray queries, the traversal runs inside the same compute shader: no shader table, no payload, no scheduling,
and the compiler keeps the path's state in registers. The more rays per path and the less work between them, the
more this matters; how much depends on the scene (2 to 6 times here):

- **Visibility rays**: every vertex traces one to the light; the pipeline pays its overhead for these short
  queries too.
- **Time-of-flight work**: the time-of-flight passes add more rays per path (to the laser spot, ellipsoidal
  connections, the traced endpoints of shift mappings) and more state (path lengths, gates, reservoirs), which
  makes the pipeline's overhead larger still.

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
small `.pyscene` file, and turns off the scene's environment map and emissive lights; `InlinePathTracer` gets the
same light from `LaserLight`. Run it with the tutorials' Cornell box (the default), or with any pbrt scene and a
resolution:

```bash
python inline_ray_tracing.py                                   # Cornell box, 1024 x 1024
python inline_ray_tracing.py veach-ajar/scene-v4.pbrt 1920 1080
```

*Veach, Ajar* and *Kitchen* are by Benedikt Bitterli (pbrt-v4 versions of his
[rendering resources](https://benedikt-bitterli.me/resources/)). *Kitchen* has area lights; delete their `AreaLightSource`
lines (and the `"rgb L"` line after each) before timing, since Falcor's `PathTracer` still shows emissive surfaces it hits.

The full script: {download}`inline_ray_tracing.py <code/inline_ray_tracing.py>`.
