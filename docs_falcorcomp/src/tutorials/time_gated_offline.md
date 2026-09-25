# Time-gated rendering (offline)

This tutorial renders a time-gated image of the Cornell box offline with
`TimeGatedPathTracerInline`: only light whose total path length (laser -> scene -> camera) falls
inside a gate reaches the image. The scene is the Cornell box without its area light, so a laser is
the only light: download {download}`scene-v4-nolight.pbrt <scenes/cornell-box/scene-v4-nolight.pbrt>`
and save it as `cornell-box/scene-v4-nolight.pbrt` next to the script. The other tutorials use the
same file. (The Cornell box is by Benedikt Bitterli, released under
{download}`CC0 <scenes/cornell-box/LICENSE.txt>`.)

```{image} images/time_gated_offline.png
:alt: Time-gated Cornell box
:width: 360px
:align: center
```

## 1. Load the scene

```{literalinclude} code/time_gated_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

`VBufferRT` finds the primary hits and `LaserVBufferRT` places the laser. The tracer keeps paths
whose length lies in a box gate of width `timeGateWindow` centered at `timeMin` (equal to
`timeMax` for a single gate). `AccumulatePass` averages the frames and `ToneMapper` makes a
displayable copy.

```{literalinclude} code/time_gated_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

Each frame traces `samplesPerPixel` paths per pixel and adds them to the accumulated image.

```{literalinclude} code/time_gated_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Save the image"
```

## 4. Save the image

Output 0 is the linear radiance (EXR); output 1 is the tone-mapped image (PNG).

```{literalinclude} code/time_gated_offline.py
:language: python
:start-after: "# 4. Save the image"
```

The full script: {download}`time_gated_offline.py <code/time_gated_offline.py>`.
