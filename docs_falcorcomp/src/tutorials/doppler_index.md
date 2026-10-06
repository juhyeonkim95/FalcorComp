# Doppler rendering

Some sensors measure how fast the scene moves. A coherent lidar with **optical heterodyne detection** (OHD) mixes the
returning light with its own laser, and the beat frequency reveals each path's Doppler shift; an **FMCW lidar**
chirps its laser, so that the beat frequency also reveals the path length. A **Doppler time-of-flight** (D-ToF)
camera is a continuous-wave ToF camera whose light and sensor are modulated at slightly different frequencies, so that
light from static objects cancels over the exposure and moving objects remain.

| Measurement | Output | Render pass |
|---|---|---|
| **Doppler spectrum (OHD)** | `H × W × B`: for every pixel, the light at each Doppler shift | `DopplerHistogramPathTracerInline` |
| **Doppler-gated image (OHD)** | `H × W`: the light whose Doppler shift falls inside a gate | `DopplerGatedPathTracerInline` |
| **FMCW spectra (OHD)** | `H × W × B`, twice: the light at each beat frequency on the up- and the down-chirp, which depends on the path length and the Doppler shift | `DopplerHistogramPathTracerInline` with a chirp |
| **Doppler ToF** | `H × W`: the heterodyne (or homodyne) measurement over the exposure | `DopplerToFPathTracerInline` |

All of them take the objects' velocities as a property (see
[Velocities](#doppler-velocities)). The OHD passes never move the scene: a path's Doppler shift follows from the
velocities of its vertices. The D-ToF pass moves the objects during the exposure, so they must be built as animated.
`VelocityGroundTruthInline` renders the reference velocity maps.

For an introduction to the two sensing principles side by side, see the
[Doppler rendering tutorial](https://juhyeonkim95.github.io/project-pages/doppler_tutorial/), which compares OHD and
Doppler ToF.

- **Scenes:** the OHD tutorials use the Cornell box of the other tutorials,
  {download}`scene-v4-nolight.pbrt <scenes/cornell-box/scene-v4-nolight.pbrt>`, saved as
  `cornell-box/scene-v4-nolight.pbrt`. The D-ToF tutorial uses the same box with movable boxes,
  {download}`scene.pyscene <scenes/cornell-box-moving/scene.pyscene>` with its meshes
  ({download}`Floor <scenes/cornell-box-moving/meshes/Floor.ply>`,
  {download}`Ceiling <scenes/cornell-box-moving/meshes/Ceiling.ply>`,
  {download}`BackWall <scenes/cornell-box-moving/meshes/BackWall.ply>`,
  {download}`LeftWall <scenes/cornell-box-moving/meshes/LeftWall.ply>`,
  {download}`RightWall <scenes/cornell-box-moving/meshes/RightWall.ply>`,
  {download}`ShortBox <scenes/cornell-box-moving/meshes/ShortBox.ply>`,
  {download}`TallBox <scenes/cornell-box-moving/meshes/TallBox.ply>`), saved as `cornell-box-moving/scene.pyscene`
  and `cornell-box-moving/meshes/*.ply`.
- **Light:** a point light at the camera, set on `LaserLight`.
- **Extra package:** the scripts plot with matplotlib (`pip install matplotlib`).

## Tutorials

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Doppler spectrum (OHD, offline)
:img-top: images/thumbnails/doppler_spectrum_thumb.jpg
:img-alt: Mean Doppler shift of the Cornell box with a box coming closer and a box moving away
:link: doppler_spectrum_offline
:link-type: doc

Render the Doppler spectrum of the Cornell box with `DopplerHistogramPathTracerInline` while its boxes move, look
at the spectra of single pixels, and render a single Doppler-gated image with `DopplerGatedPathTracerInline`.
```

```{grid-item-card} FMCW lidar (offline)
:img-top: images/thumbnails/fmcw_lidar_thumb.jpg
:img-alt: Distance and velocity of the Cornell box recovered from FMCW up- and down-chirp spectra
:link: fmcw_lidar_offline
:link-type: doc

Render the up- and down-chirp spectra of an FMCW lidar with `DopplerHistogramPathTracerInline`, and recover every
pixel's distance and velocity from them, from the mean spectra and from a single measurement with speckle.
```

```{grid-item-card} Doppler ToF velocity (offline)
:img-top: images/thumbnails/doppler_tof_thumb.jpg
:img-alt: Velocity of the Cornell box's boxes estimated from Doppler ToF measurements
:link: doppler_tof_offline
:link-type: doc

Move the boxes during the exposure with `DopplerToFPathTracerInline`, estimate their velocity from a heterodyne and
a homodyne measurement, and compare it with the ground truth.
```
````

```{toctree}
:hidden:

doppler_spectrum_offline
fmcw_lidar_offline
doppler_tof_offline
```
