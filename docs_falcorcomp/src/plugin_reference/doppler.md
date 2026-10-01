# Doppler rendering

These render passes simulate measurements of moving scenes:

- [`DopplerHistogramPathTracerInline`](doppler/DopplerHistogramPathTracerInline.md): the Doppler spectrum of optical
  heterodyne detection (OHD), as in coherent lidar. Nothing moves; each path's Doppler shift follows from the
  velocities of its vertices.
- [`DopplerGatedPathTracerInline`](doppler/DopplerGatedPathTracerInline.md): the light whose Doppler shift falls in
  a gate, one image instead of the spectrum, as the time-gated path tracer is to the transient histogram.
- [`DopplerToFPathTracerInline`](doppler/DopplerToFPathTracerInline.md): Doppler time-of-flight, a continuous-wave
  ToF camera with different light and sensor modulation frequencies. The objects really move during the exposure.
- [`VelocityGroundTruthInline`](doppler/VelocityGroundTruthInline.md): ground-truth velocity maps for both.

(doppler-velocities)=
## Velocities

All four take the motion of the scene objects in the same `velocities` property: a dictionary from an object name
to its instantaneous rigid motion, v(x) = linear + angular × (x − center):

```python
"velocities": {
    "TallBox":  {"linear": [0.0, 0.0, 2.0]},                                 # m/s
    "Wheel":    {"angular": [0.0, 0.0, 30.0], "center": [0.3, 0.2, 0.0]},  # rad/s, about an axis through center
}
```

- Missing fields are zero. Velocities are in m/s and rad/s; positions are in scene units, taken as meters. Objects
  that are not listed do not move.
- A name matches a geometry instance's mesh name, its material name, or `"#<instance index>"`. A name that matches
  nothing is reported in the log. `get_object_names()` lists the names of a scene's objects.
- Falcor merges identical materials when it loads a scene, and then they lose their names (in the Cornell box, every
  white surface becomes `Floor`). Load scenes with `SceneBuilderFlags.DontMergeMaterials` to keep them; pbrt triangle
  meshes have no names, so with pbrt scenes you name objects by their material.
- `set_velocity(name, linear, angular=[0, 0, 0], center=[0, 0, 0])` sets or changes a motion from Python.

`DopplerToFPathTracerInline` and the `path_length` mode of `VelocityGroundTruthInline` move the objects, which needs
more of the scene; see [Moving objects](#doppler-tof-moving-objects).

```{toctree}
:maxdepth: 1

doppler/DopplerHistogramPathTracerInline
doppler/DopplerGatedPathTracerInline
doppler/DopplerToFPathTracerInline
doppler/VelocityGroundTruthInline
```
