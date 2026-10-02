# Depth from structured light

A structured-light system finds, for every camera pixel, the projector column that lights it, and triangulates the
camera ray with the plane of light of that column. This page renders the code images of the bunny scene with
`StructuredLightPathTracerInline`, decodes and triangulates them, and compares naive and antithetic sampling at
equal time.

```{image} images/structured_light_depth.jpg
:alt: Depth of the bunny scene from Gray and XOR codes, naive and antithetic, and the true depth
:align: center
```

## Codes

The projector shows 10 binary patterns, one bit each of a code of $2^{10} = 1024$ columns, as vertical stripes. The
signed measurement of a bit is positive where the pixel is lit by a column whose bit is 1, so its sign decodes the
bit (no threshold is needed: the pass renders the pattern in $[-1, 1]$, the difference of the pattern and its
inverse).

- The **Gray code** changes one bit between neighboring columns. Its finest bits are fine stripes, whose indirect
  light cancels, but its coarse bits are wide stripes, where the indirect light of a lit half of the scene reaches
  the other half and flips the bits there.
- The **XOR codes** (Gupta et al. 2011) XOR every Gray bit with a fine base bit: XOR-02 with the finest, XOR-04 with
  the next one. Every pattern is then fine, so the indirect light cancels in all of them, and decoding XORs the base
  bit out again. Gupta et al. combine the two: in every pixel, the code whose least certain bit is the most certain.

```{literalinclude} code/structured_light_depth.py
:language: python
:start-after: "# 5. Decode the projector column of every pixel"
:end-before: "# 7. Reconstruct"
```

## Results

```{list-table}
:header-rows: 1
:widths: 50 25 25

* - Code
  - Samples per pixel per bit
  - Pixels wrong by more than 5 cm
* - Gray, converged
  - 1,024
  - 8.8%
* - XOR-02, naive, 0.03 s per bit
  - 37
  - 10.6%
* - XOR-02 + XOR-04, naive
  - 37
  - 9.7%
* - XOR-02, antithetic, 0.03 s per bit
  - 24
  - **0.1%**
* - XOR-02 + XOR-04, antithetic
  - 24
  - **0.1%**
```

Even converged, the Gray code fails on the right wall, where indirect light flips its coarse bits. The XOR codes avoid this, but their fine patterns make the measurement small and noisy: with naive
sampling the bits on the walls and the floor are still random after 0.03 seconds. Antithetic sampling (the halves of
each block of 2 or 4 columns swapped, see [binary codes](../tutorials/structured_light_codes.md)) cancels the
indirect light pair by pair, and decodes almost every pixel in the same time. The remaining small errors are the
quantization to 1024 columns.

Pixels in the projector's shadow, next to the bunny, are left out (white).

## Projector

The projector is 0.8 to the right of the camera, looking at the middle of the box, with a 34-degree field of view
that covers everything the camera sees: a pixel outside it would get no code.

```{literalinclude} code/structured_light_depth.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "def create_graph"
```

The full script: {download}`structured_light_depth.py <code/structured_light_depth.py>`. Run it next to the unzipped
`cornell-box-bunny-diffuse` folder; it takes about two minutes.
