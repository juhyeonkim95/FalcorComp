# 3D reconstruction from structured light

A structured-light system finds, for every camera pixel, the projector pixel that lights it, and triangulates the
camera ray with the projector ray. This page renders the code images of the bunny scene with
`StructuredLightPathTracerInline`, decodes and triangulates them, and compares naive and antithetic sampling of the
indirect light at equal time.

```{image} images/structured_light_depth.jpg
:alt: The z coordinate of the bunny scene reconstructed from converged, naive and antithetic code images, and the difference from the converged result
:align: center
```

## Setup

- **Projector**: 0.1 to the right of the camera, looking the same way, with a field of view a little wider than the
  camera's (the tangent of its half angle is 0.2), so that it covers everything the camera sees.
- **Codes**: the XOR-02 and XOR-04 codes of Gupta et al. (2011), 10 bits for $2^{10} = 1024$ projector pixels, along
  both projector axes: vertical stripes code the projector column, horizontal stripes its row. Every pattern is
  fine, so the indirect light, which reaches a point from many projector pixels, largely cancels in it.
- **Images**: 1024 x 1024, with primary rays jittered over each pixel (`VBufferRT` with 32 Halton positions). Each
  code image is its direct light, rendered once and converged, plus its indirect light, rendered with each method:
  the indirect light is the noisy part.

```{literalinclude} code/structured_light_depth.py
:language: python
:start-after: "# 2. The projector and the render graph"
:end-before: "# 3. Equal time"
```

## Equal time

The script measures the time of a frame of each method, gives naive sampling 512 samples per pixel for each image,
and gives antithetic sampling the number of samples that takes the same time.

```{literalinclude} code/structured_light_depth.py
:language: python
:start-after: "# 3. Equal time: the cost of a frame of each method"
:end-before: "# 4. Capture the code images"
```

## Decode and triangulate

The pass renders each pattern signed, in $[-1, 1]$ (the difference of the pattern and its inverse), so a bit is 1
where its image is positive; dividing by the white image gives every pixel the same scale, for the confidence below.
The XOR codes are undone with their base bit, and the Gray code is turned into the projector index.

```{literalinclude} code/structured_light_depth.py
:language: python
:start-after: "# 5. Decode the projector pixel of every camera pixel"
:end-before: "# 6. Triangulate the camera ray with the projector ray"
```

The column and the row give the projector ray, and the reconstructed point is the midpoint of the closest points of
the camera ray and the projector ray. The two codes are averaged, each weighted by its confidence in the pixel: the
product of the magnitudes of its normalized bit images, small where a bit is close to its threshold.

```{literalinclude} code/structured_light_depth.py
:language: python
:start-after: "# 6. Triangulate the camera ray with the projector ray"
:end-before: "results = ["
```

## Results

The top row shows the z coordinate of the reconstructed points; the bottom row, how far each reconstruction is from
the one from converged images.

```{list-table}
:header-rows: 1
:widths: 40 30 30

* - Indirect light
  - Samples per pixel per image
  - Pixels off by more than 0.05
* - Naive
  - 512
  - 2.4%
* - Antithetic (same time)
  - 282
  - **1.3%**
```

With naive sampling, the noise of the indirect light flips bits wherever the direct light of a pattern is close to
zero: at the edges of the stripes, and across the walls, the ceiling and the floor, where the indirect light is
strong. Antithetic sampling (the halves of each block of 2 or 4 projector pixels swapped, see
[binary codes](../tutorials/structured_light_codes.md)) cancels the indirect light pair by pair, and halves the
wrongly decoded pixels in the same time. The bunny's outline differs in both: next to it the projector is
shadowed, and the pixels there have no reliable code.

The full script: {download}`structured_light_depth.py <code/structured_light_depth.py>`. Run it next to the unzipped
`cornell-box-bunny-diffuse` folder; it takes about five minutes, most of it for the converged images.
