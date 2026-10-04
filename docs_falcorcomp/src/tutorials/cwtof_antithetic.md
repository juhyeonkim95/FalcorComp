# CW-ToF: antithetic sampling and the modulation wavelength

This tutorial compares naive and antithetic sampling of a CW-ToF measurement at equal time for three modulation
wavelengths, with the antithetic path found by Newton's method on the barycentric coordinates of the vertex's triangle.
It builds on [CW-ToF rendering (offline)](cwtof_offline.md), which explains the render graph.

```{image} images/cwtof_antithetic.jpg
:alt: Naive and antithetic CW-ToF rendering at equal time for the wavelengths 0.02, 0.1 and 1, with references
:align: center
```

## The antithetic path

`CWToFPathTracerInline` weights each path by $\cos(2\pi\,\ell / \lambda)$, with $\ell$ the path length. With
antithetic sampling, every BSDF-sampled vertex $y$ after the primary hit gets an antithetic vertex $y'$ on its surface such that
the path is half a wavelength longer or shorter, $\ell(y') = \ell(y) \pm \lambda / 2$, where the cos has the opposite
sign. The two are combined with multiple importance sampling (see
[Antithetic sampling](#cwtof-antithetic)).

$y'$ has two coordinates on the surface and one condition on the path length, so one more condition fixes it: the
gauge. Here the antithetic vertex is found with `shiftmapMethod` = `barycentric`:

- The unknowns are the barycentric coordinates of $y'$ on $y$'s triangle, so $y'$ stays on the triangle (the shift
  fails if it would leave it).
- Newton's method solves the length condition together with `gaugeMode` = `avg_grad`: $y'$ moves along the average of
  the path-length gradients at $y$ and $y'$, which makes the backward shift return to $y$.
- The Jacobian of the map, which multiple importance sampling needs, comes from the implicit function theorem at
  the solution.

The default `radial` shift solves the same condition in closed form along a ray on the vertex's plane; it is a
little faster and exactly invertible. The Newton-based methods follow the average gradient, which can leave a small
bias where the gauge has several solutions; `antitheticRoundTripCheck` removes it at the cost of a second shift.

## 1. Load the scene

```{literalinclude} code/cwtof_antithetic.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The graph is that of [CW-ToF rendering](cwtof_offline.md), with one sample per pixel per frame, so that the frame
counts measure time finely. The two methods differ only in the antithetic options.

```{literalinclude} code/cwtof_antithetic.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render each method for the same time"
```

## 3. Render each method for the same time

Each method compiles its shaders, warms up for a second, then renders for 0.3 seconds; every frame waits for the GPU,
so the time includes all of its work.

```{literalinclude} code/cwtof_antithetic.py
:language: python
:start-after: "# 3. Render each method for the same time"
:end-before: "# 4. Compare with a reference at each wavelength"
```

## 4. Compare at each wavelength

```{literalinclude} code/cwtof_antithetic.py
:language: python
:start-after: "# 4. Compare with a reference at each wavelength"
:end-before: "# 5. Show the images"
```

```{list-table}
:header-rows: 1
:widths: 20 25 25 15 15

* - Wavelength
  - Naive (0.3 s)
  - Antithetic (0.3 s)
  - Naive relMSE
  - Antithetic relMSE
* - 0.02
  - 525 spp
  - 301 spp
  - 1.97
  - **0.288**
* - 0.1
  - 482 spp
  - 314 spp
  - 0.301
  - **0.136**
* - 1
  - 518 spp
  - 318 spp
  - **0.0265**
  - 0.0401
```

An antithetic frame costs 50 to 75% more: it solves for an antithetic vertex and evaluates its path for every sampled vertex.
With the short wavelength, most of the indirect light cancels, and naive sampling shows only noise; antithetic
sampling, with fewer samples, already shows the rings and stripes of the reference, at a 7 times lower error. The
gain shrinks as the wavelength grows: the antithetic path, half a wavelength longer or shorter, is farther from the sampled one and less similar
to it, and the measurement no longer cancels much. At $\lambda = 1$, comparable to the size of the box, naive
sampling is better for the same time.

## 5. Show the images

The images are signed: a diverging colormap shows 0 in white, positive values in red and negative ones in blue,
with the range of each row set by the reference.

```{literalinclude} code/cwtof_antithetic.py
:language: python
:start-after: "# 5. Show the images"
```

The full script: {download}`cwtof_antithetic.py <code/cwtof_antithetic.py>`. It takes about two minutes, most of it
for the references.
