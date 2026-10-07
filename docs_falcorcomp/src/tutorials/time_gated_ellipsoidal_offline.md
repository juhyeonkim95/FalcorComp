# Ellipsoidal sampling (offline)

This tutorial compares the three ways `TimeGatedPathTracerInline` connects a camera path to the
laser spot, at equal rendering time, on a narrow gate.

With `direct` sampling, every vertex $x$ of the camera path is connected straight to the laser
spot. The length of that connection is whatever the geometry makes it, so with a narrow gate only
the few paths whose total length happens to fall inside the gate contribute, and the image is
noisy. `ellipsoidal` sampling instead inserts a new vertex $y$ on the scene so that the path
$x \to y \to$ laser spot has a length inside the gate: all such $y$ lie on an ellipsoid with foci
$x$ and the laser spot, and the pass samples $y$ where that ellipsoid crosses a scene triangle.
Every path sampled this way fits the gate. `ellipsoidal_direct_mis` uses both techniques and
combines them with multiple importance sampling (balance heuristic). See
[Connection sampling](#connection-sampling) in the plugin reference.

The scene is the Cornell box with a diffuse dragon, lit by the same laser as the other tutorials:
download {download}`scene-v4-nolight.pbrt <scenes/cornell-box-dragon-diffuse/scene-v4-nolight.pbrt>`
and save it as `cornell-box-dragon-diffuse/scene-v4-nolight.pbrt` next to the script. The scene
also needs the dragon mesh, `meshes/dragon.ply` next to the `.pbrt` file, which is not included
here. (The Cornell box is by Benedikt Bitterli, released under
{download}`CC0 <scenes/cornell-box-dragon-diffuse/LICENSE.txt>`.)

```{image} images/time_gated_ellipsoidal_equal_time.jpg
:alt: Equal-time comparison of direct, ellipsoidal and ellipsoidal + direct MIS sampling
:align: center
```

```{list-table}
:header-rows: 1
:widths: 40 20 20 20

* - `samplingMethod` (2 seconds)
  - Frames
  - Samples per pixel
  - relMSE
* - `direct`
  - 43
  - 1,376
  - 0.583
* - `ellipsoidal`
  - 7
  - 224
  - 0.317
* - `ellipsoidal_direct_mis`
  - 7
  - 224
  - 0.0510
```

Each image renders at 1024 x 1024 with 32 samples per pixel per frame and a 0.01-wide gate. The
bottom row enlarges the dragon's head. An ellipsoidal frame costs about six times a direct one, so
it renders far fewer samples in the same time, but with MIS its error is 11 times lower. The
error is the relative mean squared error against a path-traced reference with 262,144 samples per
pixel. These numbers were measured on an NVIDIA GeForce RTX 3090 with Vulkan.

## How the ellipsoidal vertex is sampled

The ellipsoidal connection follows Pediredla et al. (2019), with one change that makes it practical on a GPU: how the
scene triangle that holds $y$ is chosen. The original method tests the ellipsoid against the bounding boxes of a BVH
and against the triangles in its leaves, and collects *every* triangle the ellipsoid crosses, then picks one from
the list. On a GPU this list is the problem: for detailed meshes it can hold thousands of triangles per connection,
far more than a thread can keep, which spills registers and memory.

`TimeGatedPathTracerInline` never builds the list. It samples the triangle by walking a BVH, the light BVH that
Falcor builds for emissive triangles, here built over all the scene's triangles (`ellipsoidTriangleSampler` = `LightBVH`):

1. **Length**: the length of $x \to y \to$ laser spot is drawn from the gate, and with $x$ and the laser spot as
   foci it defines the ellipsoid.
2. **Node**: from the root, the walk goes into one of the two children at random, with a weight equal to the total
   area of the child's triangles, or zero if the child's bounding box does not intersect the ellipsoid. Large
   regions near the ellipsoid are visited more often, and regions it cannot reach are never visited.
3. **Triangle**: in the leaf, one of the triangles the ellipsoid actually crosses is picked.
4. **Point**: $y$ is sampled on the curve where the ellipsoid crosses the triangle (an ellipse in the triangle's
   plane, clipped to the triangle): in coordinates where the ellipsoid is the unit sphere, the curve is a circle, and
   $y$ is uniform in angle over its arcs inside the triangle.
5. **Visibility**: a ray from $x$ towards $y$ must hit that triangle first; otherwise the sample is rejected.

The probability of every step is known, so the density of $y$ is too, and it is recomputed for multiple importance
sampling by walking the BVH again. The bounding-box test is conservative: a leaf can be reached whose triangles the
ellipsoid misses, and that sample then fails instead of being drawn again. This keeps the cost of a connection to
one walk down the tree, at the price of some failed samples.

Two more changes from the original method:

- **MIS with direct connections**: `ellipsoidal_direct_mis` combines the ellipsoidal technique with BSDF sampling
  followed by a direct connection, so that specular and glossy surfaces, where an ellipsoidal vertex has almost no
  BSDF value, are still sampled well.
- **Connections to the light only**: the ellipsoidal vertex is inserted only when the camera path connects to the
  laser spot (next-event estimation), not between subpaths as in bidirectional path tracing.

`ellipsoidTriangleSampler` = `Uniform` picks any scene triangle with the same probability, without looking at the
ellipsoid, as a baseline: most of its samples miss.

## 1. Load the scene

```{literalinclude} code/time_gated_ellipsoidal_equal_time.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build a render graph"
```

## 2. Build the render graph

The graph is the one from [Time-gated rendering (offline)](time_gated_offline.md); only
`samplingMethod` changes between the three renders. The other ellipsoidal options keep their
defaults: the scene triangle is chosen with a light BVH over the scene's triangles
(`ellipsoidTriangleSampler`), and with `ellipsoidal` only vertices rougher than
`specularRoughnessThresholdEllipsoid` (0.25) insert an ellipsoidal vertex.

```{literalinclude} code/time_gated_ellipsoidal_equal_time.py
:language: python
:start-after: "# 2. Build a render graph"
:end-before: "# 3. Render each method"
```

## 3. Render each method for the same time

As in the [ReSTIR equal-time comparison](time_gated_restir_offline.md), the
timing waits for the GPU after every frame and leaves out a few warm-up frames, in which the
shaders are compiled and the triangle sampler is built.

```{literalinclude} code/time_gated_ellipsoidal_equal_time.py
:language: python
:start-after: "# 3. Render each method"
:end-before: "# 4. Compare with the reference"
```

## 4. Compare with the reference

If there is no `reference.npy`, the script first renders one with `direct` sampling and 262,144
samples per pixel, which takes about 7 minutes on an RTX 3090, and saves it for later runs.

```{literalinclude} code/time_gated_ellipsoidal_equal_time.py
:language: python
:start-after: "# 4. Compare with the reference"
:end-before: "# 5. Save the comparison"
```

## 5. Save the comparison

```{literalinclude} code/time_gated_ellipsoidal_equal_time.py
:language: python
:start-after: "# 5. Save the comparison"
```

The full script:
{download}`time_gated_ellipsoidal_equal_time.py <code/time_gated_ellipsoidal_equal_time.py>`. With
the reference in place, it takes under a minute.
