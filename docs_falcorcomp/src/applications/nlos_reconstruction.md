# Hidden objects from time-gated images

Non-line-of-sight (NLOS) imaging recovers objects that the camera cannot see, from light that reaches them by way of
a visible wall, the *relay wall*, and comes back the same way. In scanning NLOS (Pediredla et al. 2019), a laser lights
one point of the wall at a time and a time-gated camera keeps only the light whose path has a chosen length, so that
the light focuses, in time, on one point of the hidden scene. This page scans a dragon out of the camera's view, voxel
by voxel, renders the scan with four time-gated renderers at about equal frame time, and reconstructs the dragon from
each.

```{image} images/nlos_reconstruction.jpg
:alt: A frame of each renderer, and the dragon reconstructed from each renderer's scan
:align: center
```

## The scan

The camera and the laser sit at $O = (-1, 0, 4)$ and look at the relay wall, the plane $z = 0$. The dragon, pressed
flat, stands on the plane $z = 4$ around $(2, 0, 4)$, out of the camera's view. A square of side 1 around it is
divided into $25 \times 25$ voxels.

For a voxel $V$, the scan sets a path length

$$
\tau = |O - C| + |C - V| + 0.5,
$$

with $C$ the camera's target on the wall, gates the camera at the total path length $2\tau$ (a box of width 0.01), and
aims the laser at 16 points $W$ of the *illumination ellipse* $\{W : |O - W| + |W - V| = \tau\}$ on the wall, one frame
each. Light that goes from such a $W$ to $V$ and back to a point $W'$ of the wall reaches the camera within the gate
when $|V - W'| + |W' - O| = \tau$: the *detection ellipse*, the same curve. So if $V$ is on the dragon, every frame of
its scan lights the whole detection ellipse; if $V$ is empty, only the parts of it that other points of the dragon
happen to reach with the same path length.

## The renderers

- **Path tracing** (`samplingMethod` `direct`) connects every path vertex to the laser spot; a path counts only if its
  length falls into the gate by chance.
- **Ellipsoidal path tracing** (`ellipsoidal`) inserts a vertex on the dragon whose position makes the path's length
  fit the gate (see [Ellipsoidal sampling](../tutorials/ellipsoidal_index.md)).
- **Ellipsoidal + naive reuse**: `TimeGatedReSTIRInline` with ellipsoidal candidates, temporal reuse along the scan
  (with `isSceneDynamic`, since the laser moves every frame) and spatial reuse, with the shift `no`: a reused path keeps
  its vertices, so its length changes and it often no longer fits the gate.
- **Ellipsoidal + ToF ReSTIR**: the same, with the shift `ray_trace`, which moves the reused path's vertex on the
  dragon so that the path keeps a length in the gate (see [ToF rendering with ReSTIR](../tutorials/restir_index.md)).

The renderers take 500, 52, 38 and 32 samples per pixel per frame, in this order, for about the same time per frame,
which the script measures on the first 50 voxels of the scan. ToF ReSTIR stops its Newton solves after 5 iterations
(`NewtonMaxIteration`).

## The score

For each voxel, the score reads its 16 frames along the detection ellipse, at 64 points. With $L_j$ the samples of
frame $j$ and $G$ the geometric mean of values clipped to $[10^{-6}, 1]$,

$$
s = G\left(G(L_1)^{0.7}, \dots, G(L_{16})^{0.7}\right)^{0.7}.
$$

A geometric mean is high only if all its values are: the score is high when the ellipse is lit all along, in every
frame, and a sample without light counts as $10^{-6}$. The figure shows the scores, on one color range for all the
renderers, and each renderer's scores divided by their sum over the voxels, which compares the shapes regardless of the
overall level.

## 1. Load the scene

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Plan the scan"
```

## 2. Plan the scan

The voxels, their path lengths, the points of the two ellipses on the wall, and their pixels in the camera image.

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 2. Plan the scan"
:end-before: "# 3. Build a render graph for each renderer"
```

## 3. Build a render graph for each renderer

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 3. Build a render graph for each renderer"
:end-before: "# 4. Render the scan"
```

## 4. Render the scan

Every voxel sets the gate with `set_time_gate_info`, and every frame moves the laser with `update_laser_info`. Both
keep ReSTIR's history, so temporal reuse runs along the whole scan.

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 4. Render the scan"
:end-before: "# 5. Measure the frame time"
```

## 5. Measure the frame time

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 5. Measure the frame time"
:end-before: "# 6. Score every voxel"
```

## 6. Score every voxel

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 6. Score every voxel"
:end-before: "# 7. Show a frame and the reconstructions"
```

## 7. Show a frame and the reconstructions

The dragon's outline comes from its mesh: the cells of a grid 4 times finer than the voxels that hold a vertex.

```{literalinclude} code/nlos_reconstruction.py
:language: python
:start-after: "# 7. Show a frame and the reconstructions"
```

```{list-table}
:header-rows: 1
:widths: 40 15 20 25

* - Renderer
  - spp
  - ms per frame
  - Median score
* - Path tracing
  - 500
  - 5.3
  - 0.0019
* - Ellipsoidal path tracing
  - 52
  - 5.3
  - 0.0174
* - Ellipsoidal + naive reuse
  - 38
  - 5.9
  - 0.0167
* - Ellipsoidal + ToF ReSTIR
  - 32
  - 5.3
  - 0.0174
```

The frames show why the gate needs ellipsoidal sampling: path tracing finds a path that fits the gate for about 1% of
the pixels, so the detection ellipse stays almost dark, and its scores stay near the floor everywhere. The three
ellipsoidal renderers light most of the ellipse in every frame and reconstruct the dragon alike: its body and the gaps
between its coils, brightest on the left, where the voxels are closest to the part of the wall that the laser and the
camera see. At this frame time, ellipsoidal sampling alone finds a path for most pixels, and reuse changes the scores
little.

The full script: {download}`nlos_reconstruction.py <code/nlos_reconstruction.py>`. It takes about 11 minutes.

## Limitations

- The score is a heuristic: it blurs the dragon over a few voxels, and it fades to the right, where the voxels are
  farther from the wall and less light comes back.
- The detection ellipses of the four rightmost columns of voxels leave the camera's image in part (up to 11% of their
  samples); their scores use the samples inside it.

## References

- A. Pediredla, A. Dave and A. Veeraraghavan. SNLOS: Non-line-of-sight scanning through temporal focusing. *IEEE
  International Conference on Computational Photography* (ICCP), 2019.
- A. Velten, T. Willwacher, O. Gupta, A. Veeraraghavan, M. G. Bawendi and R. Raskar. Recovering three-dimensional shape
  around a corner using ultrafast time-of-flight imaging. *Nature Communications* 3, 745, 2012.
