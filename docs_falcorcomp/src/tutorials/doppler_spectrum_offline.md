# Doppler spectrum (OHD, offline)

This tutorial renders the Doppler spectrum that a coherent lidar with optical heterodyne detection measures, with
`DopplerHistogramPathTracerInline`. The tall box of the Cornell box comes towards the camera at 20 m/s and the short
box moves away at 20 m/s. With a 1550 nm laser and the light next to the camera, light reflected once by a box is
shifted by $2v/\lambda \approx \pm 26$ MHz; light that bounces between the boxes and the walls spreads over other
shifts. Nothing in the scene actually moves: each path's shift follows from the velocities of its vertices.

It uses the scene described in [Doppler rendering](doppler_index.md).

```{image} images/doppler_spectrum.jpg
:alt: The Cornell box's steady image, mean Doppler shift and three pixels' spectra
:align: center
```

## 1. Load the scene

The scene is loaded with `DontMergeMaterials`: Falcor otherwise merges identical materials, and every white surface,
the two boxes included, would be called `Floor`. With it, each object keeps the name of its material, which the
velocities refer to.

```{literalinclude} code/doppler_spectrum_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`LaserLight` puts a point light at the camera (`isLightSourceLaser = false`, `laserCollocated = true`). The tracer's
spectrum is set by:

- `wavelength`: the laser wavelength, in nm, which turns path velocities into Doppler shifts.
- `frequencyMin`, `frequencyMax`, `frequencyBin`: 256 bins from -100 to 100 MHz.
- `velocities`: the motion of each object, by name; the camera looks along $-z$, so $+z$ is towards it.
- `accumulate`: sum the frames in the spectrum, as the transient histogram tracer does.

`computeDirect` is on: the single reflection off each box is the strongest part of the signal.

```{literalinclude} code/doppler_spectrum_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

```{literalinclude} code/doppler_spectrum_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Read the spectrum"
```

## 4. Read the spectrum

`to_numpy()` returns the spectrum as bins x height x width x RGBA, in radiance per MHz.

```{literalinclude} code/doppler_spectrum_offline.py
:language: python
:start-after: "# 4. Read the spectrum"
:end-before: "# 5. Show the image"
```

## 5. Show the image, the mean shift and three spectra

Summed over all shifts, the spectrum is the ordinary image. Its mean shift per pixel shows the tall box at about
+26 MHz and the short box at about -26 MHz, and the walls next to each box tinted by light that reached them through
the box. The three spectra show the single-reflection peaks of the two boxes and of the static back wall (at 0), and
the spread of light that bounced between moving and static surfaces; the tall box's spectrum reaches 50 to 65 MHz
through paths that meet it twice.

```{literalinclude} code/doppler_spectrum_offline.py
:language: python
:start-after: "# 5. Show the image"
```

The full script: {download}`doppler_spectrum_offline.py <code/doppler_spectrum_offline.py>`. It takes about 10 seconds.
