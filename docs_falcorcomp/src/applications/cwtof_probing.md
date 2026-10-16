# Depth without multipath: transport probing

A CW-ToF camera measures depth from the phase of its modulated light. Light that bounces between surfaces arrives
along longer paths and pulls the phase: the multipath error. O'Toole et al. (2014) remove it by probing the light
transport. A projector, modulated like the camera's light, shows patterns while the camera masks its pixels in step,
so that the sensor keeps only the light that leaves the projector and comes back along the same line: the direct and
the retro-reflective light. This page renders their coaxial setup, a projector at the camera, with the projector of
`LaserLight` and the transport probing of `CWToFPathTracerInline`, and recovers depth without the multipath error.

```{image} images/cwtof_probing.jpg
:alt: The measurement with and without probing, and the depth error of the conventional, probed and masked measurements
:align: center
```

## The measurement

With `phaseShift` set to `(0, 0.25, 0)` and the `cos` waveform, the red and green channels hold the real and
imaginary parts of the complex measurement

$$
I = \sum_{\text{paths}} f\, e^{2\pi i\, \ell / \lambda},
$$

from the same paths, $f$ the path's contribution and $\ell$ its length (the scene and the light are gray). Its phase
gives the path length up to multiples of $\lambda$; for the direct light, the path length is twice the depth $d$:

$$
d = \frac{\lambda}{4\pi} \arg I .
$$

The modulation is 20 MHz, $\lambda = 15$ m of path length, longer than the round trips in this scene, so the phase
does not wrap. The indirect light adds longer paths, so the conventional phase, and the depth, come out too large.

## Transport probing

A path leaves the light along its projector ray $j$, to its last vertex, and reaches the camera along its camera ray
$i$, from its first vertex. Transport probing (O'Toole et al. 2012) weights it by $\Pi(i, j)$:

- `epipolar`: $\Pi = 1$ when the projector ray is the camera ray, within half a pixel, and 0 otherwise. The direct
  light, the surface on the camera ray lit by the projector, always passes, and so does retro-reflective light,
  which comes back along the same rays (by way of a mirror, for example). Indirect light almost never does.
- `non_epipolar`: $1 - \Pi$, the indirect light.
- `masks`: what a camera does (O'Toole et al. 2014, Algorithm 2). During the exposure, $K$ random binary masks $m_k$
  of the camera's rows take turns, each with its complement $1 - m_k$ shown by the projector on the same rows. A path
  keeps $\frac{4}{K} \sum_k m_k(\text{row}_i) \left(1 - m_k(\text{row}_j)\right)$: zero when its projector row is its
  camera row, and one on average otherwise. The measurement estimates the non-epipolar light, and the conventional
  measurement minus it, the direct and retro-reflective light (their Algorithm 3).

In general the lines are the epipolar planes, through the camera and the projector; with the projector at the
camera, they all hold the camera ray, hence the rays and the rows (see [Transport probing](#cwtof-probing)).

## The algorithms of the paper

The pass computes each of the paper's photos in one render:

- **Algorithm 1**, a PMD photo: the camera captures four images $i_1, \dots, i_4$ with the correlation
  $\frac{1}{2}\cos + \frac{1}{2}$ delayed by 0, 1/4, 1/2 and 3/4 of a period (`unsignedModulation`, `phase`), and
  $I = (i_1 - i_3) + i\,(i_2 - i_4)$. The differences cancel the constant half path by path, so `phaseShift`
  `(0, 0.25, 0)` with the signed `cos` renders $I$ directly.
- **Algorithm 2**, a probed PMD photo: the $K$ masks and patterns take turns during one exposure,
  $\frac{1}{K} \sum_k m_k \odot I(p_k)$, a sum that `masks` evaluates path by path (times 4: a path between two rows
  passes a mask and its pattern a quarter of the time).
- **Algorithm 3**, the direct and retro-reflective photo: the conventional photo minus the probed one.

Step 6 runs the algorithms as a camera does, exposure by exposure. With the masks of `masks` and the same paths in
every exposure, the two give the same photos, to float rounding, apart from a few paths that land on the edge of a
row.

## 1. Build the scene

A white concave corner, the floor and two walls, with a box in it: light bounces between the faces.

```{literalinclude} code/cwtof_probing.py
:language: python
:start-after: "# 1. Build the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The light is the point light at the camera, as a projector (`projector`) with the camera's field of view, showing a
constant pattern. Each measurement builds a new graph with the probing given.

```{literalinclude} code/cwtof_probing.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Measure, with and without probing"
```

## 3. Measure, with and without probing

A new graph starts from the same random numbers, so all four measurements trace the same paths: the epipolar and
non-epipolar measurements add up to the conventional one, to $10^{-6}$. The non-epipolar light is 19% of the
epipolar light.

```{literalinclude} code/cwtof_probing.py
:language: python
:start-after: "# 3. Measure, with and without probing"
:end-before: "# 4. Depth from the phase"
```

## 4. Depth from the phase

The true depth is the distance from the camera to the world positions of `GBufferRT`.

```{literalinclude} code/cwtof_probing.py
:language: python
:start-after: "# 4. Depth from the phase"
:end-before: "# 5. Show the measurements and the depth errors"
```

## 5. Show the measurements and the depth errors

```{list-table}
:header-rows: 1
:widths: 50 25 25

* - Depth from
  - Median error
  - 95th percentile
* - The conventional measurement
  - 101 mm
  - 162 mm
* - The epipolar measurement
  - **0.00 mm**
  - **0.03 mm**
* - The conventional measurement minus the masks ($K = 128$)
  - 7.7 mm
  - 25 mm
```

The indirect light biases the conventional depth by about 10 cm, the most on the floor near the corner, where the
light bounces between the faces. The epipolar measurement keeps the direct light alone, and the indirect light that
happens to return within half a pixel of the camera ray: its depth error is a few hundredths of a millimeter. The
masks remove most of the indirect light but not all of it: with 128 fixed random masks, each indirect path is
weighted by a random factor around one (about 15% off), and all the pixels of a row share the row's masks, so the
error comes in rows of a few millimeters. It falls about as $1/\sqrt{K}$: a median of 29 mm with 8 masks, 14 mm with
32 and 7.7 mm with 128.

```{literalinclude} code/cwtof_probing.py
:language: python
:start-after: "# 5. Show the measurements and the depth errors"
:end-before: "# 6. The paper's algorithms, one exposure at a time"
```

## 6. The algorithms, one exposure at a time

A camera captures these photos in exposures. Algorithm 1 takes four raw images, each in an exposure of its own, with
the correlation $\frac{1}{2}\cos + \frac{1}{2}$ delayed by a quarter period from one to the next
(`unsignedModulation` and `phase`). Algorithm 2 runs within each of them: the $K$ random masks of the camera's rows
take turns, here for 4 frames each, while the projector shows their complements on its rows (`set_pattern_data` sets
the row pattern; the masks multiply the rows of each frame). One graph renders the exposures frame by frame, without
accumulation, so that each has its own noise, as on a camera.

```{literalinclude} code/cwtof_probing.py
:language: python
:start-after: "# 6. The paper's algorithms, one exposure at a time"
```

```{list-table}
:header-rows: 1
:widths: 50 25 25

* - Depth from
  - Median error
  - 95th percentile
* - Algorithm 1, the conventional photo
  - 101 mm
  - 163 mm
* - Algorithm 3, the direct photo ($K = 128$)
  - 11 mm
  - 38 mm
```

The conventional photo has the multipath error of step 5. Algorithm 3 removes most of it, and leaves a little more
than the photos of step 5 (7.7 mm): its 128 masks are other random masks, with their own errors along the rows, and
its 4 × 128 short exposures add their own noise.

The full script: {download}`cwtof_probing.py <code/cwtof_probing.py>`. It builds its scene and takes under a minute.

## Limitations

- The projector reaches a surface by a connection from it (next-event estimation), so light that reflects off a
  mirror on its way from the projector to a diffuse surface (a caustic) is not rendered. The paper separates such
  caustic light further, with high-frequency patterns.
- With the projector beside the camera (`laserCollocated` off), the lines are the epipolar planes: the probing works
  the same way, and the indirect light within one line, a band through the image, stays with the direct light.

## References

- M. O'Toole, R. Raskar and K. N. Kutulakos. Primal-dual coding to probe light transport. *ACM Transactions on
  Graphics* (SIGGRAPH) 31(4), 2012.
- M. O'Toole, F. Heide, L. Xiao, M. B. Hullin, W. Heidrich and K. N. Kutulakos. Temporal frequency probing for 5D
  transient analysis of global light transport. *ACM Transactions on Graphics* (SIGGRAPH) 33(4), 2014.
