# Laser visualization (offline)

This tutorial draws the laser's beam over a time-gated image of the Cornell box with `LaserPositionViewer`. Seeing
the beam helps to place the laser, and to read a time-gated image: the gate selects the light that left the laser
spot a given time ago.

It uses the same scene file as the other tutorials (see [ToF rendering](index.md)).

```{image} images/laser_visualization_offline.png
:alt: A time-gated image, the same image with the collimated beam drawn over it, and with a 2-degree cone and its spot
:align: center
```

## 1. Load the scene and move the camera

The scene's camera sits next to the laser and looks along the beam, so the beam would show as a single point. The
script moves the camera above and to the right of the laser, and gives it a wider lens than the scene's, so that the
beam crosses the image on its way into the box.

```{literalinclude} code/laser_visualization_offline.py
:language: python
:start-after: "# 1. Load the scene and move the camera"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The time-gated path tracer and its accumulation are those of
[Time-gated rendering (offline)](time_gated_offline.md), with a gate for this camera: the path length of the light
that comes straight back from the laser spot is about 17.4 here, and the gate at 18.5 keeps the light that bounced
once more near the spot.

`LaserPositionViewer` draws over the accumulated image. It reads the laser that `LaserLight` publishes every frame,
so it needs the execution edge `add_edge("Laser", "Viewer")`, and the V-buffer, to stop the beam where it goes
behind the scene. The laser is collimated (`laserAngle` 0), a beam of no width: `beamRadius` gives it a width to
draw and `coneDensity` makes it solid. The tone mapper comes after the viewer, so the beam is drawn on linear
radiance.

```{literalinclude} code/laser_visualization_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render and save

The overlay is redrawn every frame, so it does not need to be accumulated. Output 0 is the time-gated image alone
(EXR), output 1 the image with the beam (PNG).

```{literalinclude} code/laser_visualization_offline.py
:language: python
:start-after: "# 3. Render"
```

## A diverging laser

With a cone angle, the laser lights a spot instead of a point, and the viewer draws the cone and, with `showSpot`
(on by default), the spot: the light the laser puts on each surface, without shadows. The right image above sets
`"laserAngle": 2.0` on `LaserLight` and a translucent cone on the viewer:

```python
graph.create_pass("Viewer", "LaserPositionViewer", {
    "showCone": True, "beamRadius": 0.02, "coneDensity": 1.0,
    "showSpot": True, "spotScale": 20.0,
})
```

The time-gated image changes too, as the laser now lights the whole spot. See
[`LaserPositionViewer`](../plugin_reference/misc/LaserPositionViewer.md) for all the options.

The full script: {download}`laser_visualization_offline.py <code/laser_visualization_offline.py>`.
