# Doppler ToF velocity (offline)

This tutorial simulates a Doppler time-of-flight camera with `DopplerToFPathTracerInline` and estimates the velocity
of the Cornell box's boxes from its measurements. The tall box comes towards the camera and the short box moves away,
both at 2 m/s; the light is modulated at 30 MHz, and the exposure lasts 15 ms, over which the boxes really move by
3 cm. The estimate is compared with three ground-truth velocities from `VelocityGroundTruthInline`.

It uses the movable Cornell box described in [Doppler rendering](doppler_index.md).

```{image} images/doppler_tof_velocity.jpg
:alt: Estimated D-ToF velocity next to the ground-truth D-ToF, OHD and z velocities
:align: center
```

## 1. Load the scene

The boxes are built as animated in `scene.pyscene` (`addTriangleMesh(..., True)`), which keeps each in its own node
and acceleration structure so that the tracer can move it. `DontOptimizeGraph` keeps the scene graph's nodes apart,
so that the two boxes can move differently.

```{literalinclude} code/doppler_tof_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Render a Doppler ToF measurement"
```

## 2. Render a Doppler ToF measurement

Every frame, the tracer draws a time in the exposure, moves the boxes there, and traces the paths. The measurement is
the mean over the exposure, so `AccumulatePass` averages the frames; it is created with `autoReset` off, because the
scene changes every frame.

- **Heterodyne** ($\Delta f = 1/T$): light from static objects cancels over the exposure. Every frame also renders
  the time half a heterodyne period later, where the static light has the opposite sign, with the same random numbers
  (`antithetic = half_period`, `randomReplay`), so that it cancels within each frame (see
  [Antithetic time pairs](#doppler-tof-antithetic)).
- **Homodyne** ($\Delta f = 0$): an ordinary CW-ToF measurement over the exposure. It has no half period to pair
  with, so each frame renders one time.

`timeSampling = stratified` spreads the frames' times evenly over the exposure. All pixels of a frame share its time,
so with random times the error of the time integral is the same over the whole image.

```{literalinclude} code/doppler_tof_offline.py
:language: python
:start-after: "# 2. Render a Doppler ToF measurement"
:end-before: "# 3. Heterodyne and homodyne"
```

## 3. Heterodyne and homodyne, at two sensor phases

Each measurement is rendered at sensor phases 0 and 0.25 and stored as a complex number, $C = I_0 + i\, I_{0.25}$.

```{literalinclude} code/doppler_tof_offline.py
:language: python
:start-after: "# 3. Heterodyne and homodyne"
:end-before: "# 4. Velocity from the ratio"
```

## 4. Velocity from the ratio

For a path whose length changes at the rate $\mathrm{d}\ell/\mathrm{d}t$, the ratio of the two measurements is
$\rho = \varepsilon T / (1 + \varepsilon T)$ with $\varepsilon = -f_g (\mathrm{d}\ell/\mathrm{d}t)/c$, which gives
the velocity $v = -\frac{1}{2}\,\mathrm{d}\ell/\mathrm{d}t$ along the pixel ray. With one phase only, the ratio fails
where the homodyne image crosses zero; the second phase avoids that.

```{literalinclude} code/doppler_tof_offline.py
:language: python
:start-after: "# 4. Velocity from the ratio"
:end-before: "# 5. Compare with the ground truth"
```

## 5. Compare with the ground truth

`VelocityGroundTruthInline` renders three velocities of the direct path, which differ:

- **D-ToF velocity** (`path_length`): how fast the path length along the fixed pixel ray changes, between the scene
  now and 1 ms later. This is what the measurement estimates. The pixel ray meets a moving face at a different point
  over time, so on the boxes' sides, seen at a grazing angle, it is much larger.
- **OHD velocity** (`doppler`): the velocity of the hit surface point towards the camera, as in the
  [Doppler spectrum](doppler_spectrum_offline.md) tutorial. It falls off as the cosine of the angle between the pixel
  ray and the motion.
- **z velocity** (`projection`): the boxes' velocity along the camera axis, $\pm 2$ m/s.

```{literalinclude} code/doppler_tof_offline.py
:language: python
:start-after: "# 5. Compare with the ground truth"
```

On the boxes' front faces the D-ToF velocity is +1.98 m/s and -1.99 m/s (medians). The estimate reads +2.03 m/s and
-2.07 m/s, 2.6 % and 4.3 % too large, and it does not change with more renders. The ratio assumes each path's
intensity stays constant during the exposure, but the boxes' brightness changes as they move towards or away from the
light. Relative to the Doppler term, that change shrinks as the modulation frequency grows: at 300 MHz, the estimate
is within 0.5 % of the D-ToF velocity.

The full script: {download}`doppler_tof_offline.py <code/doppler_tof_offline.py>`. It takes about 20 seconds.
