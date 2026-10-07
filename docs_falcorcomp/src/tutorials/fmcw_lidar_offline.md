# FMCW lidar (offline)

An FMCW (frequency-modulated continuous-wave) lidar sweeps the frequency of its laser linearly, a *chirp*, and mixes
the returning light with its own laser. Light that traveled longer left with an older frequency, so the beat frequency
grows with the path length; a moving surface also shifts it by its Doppler shift. A triangular chirp, up and then
down, separates the two (Kim et al. 2025, Eq. 9):

$$
f_\text{up} = f_R - f_D,
\qquad
f_\text{down} = f_R + f_D,
\qquad
f_R = \frac{B}{T}\,\frac{l}{c},
\qquad
f_D = \frac{u}{\lambda},
$$

with $B$ the chirp bandwidth, $T$ its duration, $l$ the optical path length and $u$ the path velocity. This tutorial
renders the up- and down-chirp spectra of the Cornell box with `DopplerHistogramPathTracerInline`, with the moving
boxes of the [Doppler spectrum tutorial](doppler_spectrum_offline.md), and recovers the distance and the velocity of
every pixel, from the mean spectra and from a single measurement with speckle.

It uses the scene described in [Doppler rendering](doppler_index.md).

```{image} images/fmcw_spectra.jpg
:alt: The Cornell box's steady image and the up- and down-chirp spectra of three pixels
:align: center
```

## 1. Load the scene

As in the [Doppler spectrum tutorial](doppler_spectrum_offline.md), the scene is loaded with `DontMergeMaterials`, so
that the boxes keep the names the velocities refer to. The camera position gives the true distances later.

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The graph is that of the Doppler spectrum tutorial with a chirp:

- `chirpBandwidth`, `chirpDuration`: the laser sweeps 1 GHz in 1 µs, up and then down. The range term is then
  $B/(Tc) = 3.34$ MHz per meter of path length, and with the light at the camera, 6.67 MHz per meter of distance:
  the box, 6 to 8 m away, gives 40 to 55 MHz, the same order as the ±26 MHz Doppler shift of 20 m/s.
- `frequencyMin`, `frequencyMax`, `frequencyBin`: 512 bins from 0 to 100 MHz, now of beat frequency. A bin, 0.195 MHz,
  is 2.9 cm of distance or 0.15 m/s of velocity.
- `useSingleChannel`: one value per bin, for the two spectra of 512 bins at 256 x 256.

`GBufferRT` and `VelocityGroundTruthInline` give the true distance and velocity of each pixel's primary hit.

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Read the spectra"
```

## 4. Read the spectra

With a chirp, the tracer has two outputs on the same bins: `spectrum`, the up-chirp, and `spectrumDown`, the
down-chirp. With `useSingleChannel`, `to_numpy()` returns bins x height x width.

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 4. Read the spectra"
:end-before: "# 5. Distance and velocity"
```

## 5. Distance and velocity from the two peaks

The strongest light of a pixel is its single reflection, so each spectrum peaks at that reflection's beat frequency.
Their mean is the range term and half their difference the Doppler shift. With the light at the camera, a surface at
distance $d$ moving towards the camera at $v$ has $l = 2d$ and $u = 2v$:

$$
d = \frac{c\,T}{4B}\left(f_\text{up} + f_\text{down}\right),
\qquad
v = \frac{\lambda}{4}\left(f_\text{down} - f_\text{up}\right).
$$

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 5. Distance and velocity from the two peaks"
:end-before: "# 6. A single measurement"
```

## 6. A single measurement

The rendered spectra are means. A real measurement sees speckle: the light comes from many microscopic reflectors with
random phases, and the power of each frequency bin of one measurement is exponentially distributed around the mean,
independently from bin to bin (Kim et al. 2025, Algorithm 1). One draw per bin gives a single measurement.

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 6. A single measurement"
:end-before: "# 7. Show the image"
```

## 7. Show the spectra of three pixels

The figure at the top. The approaching tall box (A, 6.78 m) peaks at 19.4 MHz on the up-chirp and 71.0 MHz on the
down-chirp, 25.8 MHz on either side of its range term (the dashed line); the receding short box (B) the other way
around, at 66.5 and 15.1 MHz; the static back wall (C) at 52.4 MHz on both. The weaker humps next to the peaks are
light that also bounced off a wall: its path is longer, and only some of its segments move with the box, so its
Doppler shift is smaller. The top axis reads a beat frequency as the distance of a static reflector; only C's peaks
are at its distance. The thin lines are one measurement: speckle changes the power of every bin by several dB.

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 7. Show the image"
:end-before: "# 8. Show the distance and velocity"
```

## 8. Show the distance and velocity

```{image} images/fmcw_reconstruction.jpg
:alt: True, reconstructed and single-measurement distance and velocity maps of the Cornell box
:align: center
```

From the mean spectra, the distance is within 7 mm of the truth at half of the pixels (a bin is 2.9 cm of distance),
and the velocity is within 0.08 m/s everywhere. From one measurement, most pixels keep their values, but where
light bounced between surfaces competes with the single reflection, along the edges and in the corners of the box,
speckle can lift a bin of that light above the peak on one of the chirps: 8 % of the pixels are off by more than
10 cm, and 5.5 % by more than 1 m/s. The few white pixels along the bottom-right corner are a crack in the scene's
meshes, where the camera rays miss.

```{literalinclude} code/fmcw_lidar_offline.py
:language: python
:start-after: "# 8. Show the distance and velocity"
```

The full script: {download}`fmcw_lidar_offline.py <code/fmcw_lidar_offline.py>`. It takes about 20 seconds.
