# Structured light: antithetic sampling for binary codes

Structured-light systems often project binary codes rather than sinusoids: a Gray code, an XOR code, or a code
designed for some purpose, which is no longer periodic. This tutorial shows that antithetic sampling still works for
them: what it needs is a map that sends every projector column to a column of the opposite value, and that is its
own inverse. It compares two kinds of codes with naive sampling at equal time:

- **Codes made of antithetic blocks**: every short block of columns holds as many 0s as 1s, so each column can be
  paired with a column of the same block. The XOR codes (Gupta et al. 2011) are of this kind.
- **Arbitrary codes**: any code with as many 0s as 1s, with no structure. Two maps pair their columns: optimal
  transport and scale-based mapping.

It builds on [Structured light: pattern wavelength](structured_light_antithetic.md); the render graph and the
equal-time rendering are the same.

## Codes made of antithetic blocks

```{image} images/structured_light_blocks.jpg
:alt: Naive and antithetic rendering of XOR-02, XOR-04 and a code of random balanced blocks of 4, with references
:align: center
```

An XOR code XORs a bit of the Gray code with a high-frequency base bit: XOR-02 with the finest bit, a 01 pattern
repeating every 2 columns, and XOR-04 with the next one, 0011 repeating every 4 columns. Within every block of 2 or 4
columns, the base bit takes both values while the Gray bit is constant, so the XOR takes both values too: swapping
the two halves of each block flips the code. This map is built into the render pass (`pattern` = `xor`).

The third code takes this further: each block of 4 columns holds two 0s and two 1s in random order, and each column
is paired with a column of the other value in its block. Such a code has no closed form, so it is given to the pass
as an `arbitrary` pattern, with the pairing as a column matching:

```{literalinclude} code/structured_light_codes.py
:language: python
:start-after: "# 2. Make the codes and their antithetic maps"
:end-before: "def random_code"
```

```{literalinclude} code/structured_light_codes.py
:language: python
:start-after: "# 5. Codes made of antithetic blocks"
:end-before: "# 6. Arbitrary codes"
```

```{list-table}
:header-rows: 1
:widths: 28 18 18 18 18

* - Code
  - Naive (0.3 s)
  - Antithetic (0.3 s)
  - Naive relMSE
  - Antithetic relMSE
* - XOR-02 (bit 6)
  - 528 spp
  - 331 spp
  - 3.57
  - **0.0550**
* - XOR-04 (bit 6)
  - 530 spp
  - 322 spp
  - 1.68
  - **0.0459**
* - Random blocks of 4
  - 514 spp
  - 325 spp
  - 3.31
  - **0.0627**
```

The antithetic column is at most one block away, so it is always close, and antithetic sampling reduces the error 35 to 65
times in the same time.

## Arbitrary codes

```{image} images/structured_light_codes.png
:alt: The first 256 columns of the two random codes, and their optimal-transport maps
:align: center
```

A random code with as many 0s as 1s has no blocks. Two maps pair its columns, both given with `set_pattern_data`:

- **Optimal transport** pairs the $k$-th 0 with the $k$-th 1, from left to right. This matching moves the columns
  the least in total (in one dimension, the sorted matching is the optimal transport between the 0s and the 1s), and
  each column moves as a whole: the map has no Jacobian. It works when the code is locally balanced, so that the
  $k$-th 0 and the $k$-th 1 are close; where one value runs ahead of the other, the matched columns drift apart.
- **Scale-based mapping** splits the code into runs of equal values and pairs each run with the next one: a run of
  0s with the following run of 1s, and back. Each run is mapped linearly onto the next, stretched or shrunk to its
  width; the pass includes the Jacobian of the stretch, the ratio of the two widths. The antithetic column is always
  in the adjacent run, but runs of different widths make the stretch, and the variance it adds, large.

```{literalinclude} code/structured_light_codes.py
:language: python
:start-after: "def random_code(seed):"
:end-before: "# 3. Build the render graph"
```

Which map is better depends on the code. The mean distance a column moves under optimal transport tells them apart:
of 200 random codes (seeds 0 to 199), the script uses one with a short distance (seed 183, 7 columns) and one
with a long one (seed 160, 46 columns).

```{literalinclude} code/structured_light_codes.py
:language: python
:start-after: "# 6. Arbitrary codes: optimal transport and scale-based maps"
:end-before: "# 7. Plot the two codes"
```

```{image} images/structured_light_arbitrary.jpg
:alt: Naive, optimal-transport and scale-based antithetic rendering of the two codes, with references
:align: center
```

```{list-table}
:header-rows: 1
:widths: 28 24 24 24

* - Code
  - Naive relMSE
  - Optimal transport relMSE
  - Scale relMSE
* - 183 (distance 7.0)
  - 0.781
  - **0.0662**
  - 0.223
* - 160 (distance 45.6)
  - 0.675
  - 0.392
  - **0.158**
```

For code 183, optimal transport moves columns 7 on average, and it is 12 times better than naive sampling and 3
times better than the scale-based map. For code 160, one value runs well ahead of the other across the middle of the
code (the band in its map above): optimal transport moves columns 46 on average, and the antithetic column lights a
different part of the scene; the scale-based map, which always maps to the adjacent run, is then 2.5 times better. Both
always beat naive sampling, which takes about 60% more frames in the same time.

The full script: {download}`structured_light_codes.py <code/structured_light_codes.py>`. It takes about four
minutes, most of it for the references.
