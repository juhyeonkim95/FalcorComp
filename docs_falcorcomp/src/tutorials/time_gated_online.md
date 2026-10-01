# Time-gated rendering (online)

This tutorial renders the Cornell box from [Time-gated rendering](time_gated_offline.md) in an
interactive window. The image converges while the camera stays still, and the settings and the
camera can be changed while it runs.

```{image} images/time_gated_online.png
:alt: The time-gated Cornell box in its window
:width: 640px
:align: center
```

## 1. Open a window and load the scene

With a window, the frame buffer takes the window size, so no `resize_frame_buffer` call is needed.

```{literalinclude} code/time_gated_online.py
:language: python
:start-after: "# 1. Open a window and load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The graph is the offline one. The window shows the first marked output, so only the tone-mapped
image is marked.

```{literalinclude} code/time_gated_online.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Run"
```

## 3. Run

`run()` renders frames until the window is closed.

```{literalinclude} code/time_gated_online.py
:language: python
:start-after: "# 3. Run"
```

## Controls

- **Camera:** drag with the mouse to look around; `W`/`A`/`S`/`D` move, `Q`/`E` move down and
  up (hold `Shift` to move faster, `Ctrl` to move slower).
- **Settings:** the *Render Graph* window has a section per pass. Under *Tracer*, *Time gate*
  sets the gate center, window and kernel; *Shift gate* moves the gate one step per frame from
  *Gate min* to *Gate max*, so the light front sweeps through the scene. The sampling method is
  below it. Under *Laser*, the laser position, direction, cone angle and type can be edited.
- **Window:** `F1` shows the help, `F2` hides the UI, `Esc` exits.

Changing a setting or moving the camera restarts accumulation. With *Shift gate* on, every gate
step restarts it too, so each gate shows a single frame of `samplesPerPixel` samples.

The full script: {download}`time_gated_online.py <code/time_gated_online.py>`.
