# Laser viewer (`LaserPositionViewer`)

This render pass shows where the laser is. It draws two things over an input image, for example a tracer's color
output:

- **The beam**, like light in fog: a cone that starts at the laser with radius `beamRadius`, widens at the laser's
  cone angle (`laserAngle` of `LaserLight`) and ends where the central beam hits the scene. A collimated beam
  (`laserAngle` 0) is a cylinder of radius `beamRadius`. A camera ray that passes a length $\ell$ inside the cone,
  before it hits the scene, is covered with opacity $1 - e^{-\rho \ell}$, with $\rho$ = `coneDensity`.
- **The spot**: the light the laser puts on the surface seen in each pixel, tinted with `spotColor`. It is the
  laser's direct light, without shadows and not time gated. A collimated beam lights a single point, so its spot
  shows in no pixel; give the laser a cone angle to see it.

The laser is the one the [`LaserLight`](#laser) pass publishes in the
frame. The beam is never drawn for a laser collocated with the camera, which would cover the image. The overlay is
recomputed every frame, so it follows the camera and the laser at once.

```{image} ../../tutorials/images/laser_visualization_offline.png
:alt: A time-gated image, the same image with the collimated beam drawn over it, and with a 2-degree cone and its spot
:align: center
```

## Parameters

```{list-table}
:header-rows: 1
:widths: 25 10 65

* - Parameter
  - Type
  - Description
* - `showCone`
  - boolean
  - Draw the beam. (Default: `false`)
* - `coneColor`
  - float3
  - Color of the beam. (Default: `[1, 0, 0]`)
* - `coneDensity`
  - float
  - Opacity per unit length inside the cone, $\rho$: a higher density makes a thin beam solid, a lower one makes a
    wide cone translucent. (Default: `5`)
* - `beamRadius`
  - float
  - Radius of the cone at the laser, in scene units; it keeps a collimated beam visible. (Default: `0.01`)
* - `showSpot`
  - boolean
  - Add the spot. (Default: `true`)
* - `spotColor`
  - float3
  - Tint of the spot. (Default: `[1, 0, 0]`)
* - `spotScale`
  - float
  - Multiplies the spot's radiance (the average of its RGB). (Default: `20`)
* - `outputSize`
  - string
  - Size of the output, as for Falcor's passes: `Default` (the frame size), `Fixed`, ... The V-buffer must have the
    same size. (Default: `Default`)
* - `fixedOutputSize`
  - uint2
  - Output size with `outputSize` `Fixed`. (Default: `[512, 512]`)
```

All of them can also be changed in the pass's panel of the Render Graph window.

## Inputs and outputs

```{list-table}
:header-rows: 1
:widths: 25 75

* - Channel
  - Description
* - `vbuffer` (input)
  - V-buffer of the camera (`VBufferRT`): the beam stops at the surface seen in the pixel, which also gets the spot.
* - `viewW` (input, optional)
  - View directions of the V-buffer, for a camera with jitter or depth of field.
* - `input` (input, optional)
  - Image to draw on. Draw on linear radiance and tone map afterwards, or draw on a tone-mapped image.
* - `output` (output)
  - The input with the beam and the spot, RGBA32Float. Without an input: the overlay alone, with premultiplied
    alpha (an image under it becomes `image * (1 - alpha) + overlay.rgb`), for a pass that blends it itself, such as
    `TransientHistogramViewer`'s `overlay` input.
```

## Example

```python
graph.create_pass("Laser", "LaserLight", {
    "laserPosition": [0.0, 1.7, 6.8], "laserDirection": [0.0, 0.0, -1.0], "laserAngle": 0.0,
})
graph.create_pass("Viewer", "LaserPositionViewer", {"showCone": True, "beamRadius": 0.02, "coneDensity": 20.0})
graph.add_edge("Laser", "Viewer")                    # the laser is set before the viewer runs
graph.add_edge("VBuffer.vbuffer", "Viewer.vbuffer")
graph.add_edge("VBuffer.viewW", "Viewer.viewW")
graph.add_edge("Accumulate.output", "Viewer.input")  # e.g. a time-gated image
graph.mark_output("Viewer.output")
```

The [laser visualization tutorial](../../tutorials/laser_visualization_offline.md) draws the beam over a time-gated
image of the Cornell box.
