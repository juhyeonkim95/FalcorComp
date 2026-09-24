# Online time-gated rendering

This tutorial renders the Cornell box from [Time-gated rendering](time_gated_offline.md) in an
interactive window. The gate moves one step each frame, so the light front sweeps through the
scene; the settings and the camera can be changed while it runs.

```{raw} html
<video src="../../_static/tutorials/time_gated_online.mp4" autoplay loop muted playsinline
       style="display: block; margin: auto; max-width: 384px; width: 100%;"></video>
```

## 1. Open a window and load the scene

With a window, the frame buffer takes the window size, so no `resize_frame_buffer` call is needed.

```{literalinclude} code/time_gated_online.py
:language: python
:start-after: "# 1. Open a window and load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The graph is the offline one, with two changes. `shiftGate` moves the gate center one step per
frame from `timeMin` toward `timeMax` in `timeBin` steps, then starts again at `timeMin`. The
window shows the first marked output, so only the tone-mapped image is marked.

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
  turns *Shift gate* off for a fixed gate that converges over time, and sets the gate center,
  range and kernel; the sampling method and light settings are below it. Under *Laser*, the laser
  position, direction and cone angle can be edited.
- **Window:** `F1` shows the help, `F2` hides the UI, `Esc` exits.

Changing a setting or moving the camera restarts accumulation. With *Shift gate* on, every gate
step restarts it too, so each gate shows a single frame of `samplesPerPixel` samples.

The full script: {download}`time_gated_online.py <code/time_gated_online.py>`.
