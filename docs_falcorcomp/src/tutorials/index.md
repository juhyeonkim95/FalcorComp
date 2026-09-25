# Rendering tutorials

These tutorials render the Cornell box lit by a laser with falcorcomp's time-of-flight render
passes. Each one is a short Python script that loads the scene, builds a Falcor render graph and
renders with it, explained step by step, with the full script at the end.

The **offline** tutorials render without a window and save the result to a file. The **online**
tutorials open an interactive window, where the image converges over frames and the camera and
the settings can be changed while it runs.

Before you start:

- Install falcorcomp (see [Installation](../getting_started/installation.md)).
- Download the scene, {download}`scene-v4-nolight.pbrt <scenes/cornell-box/scene-v4-nolight.pbrt>`,
  and save it as `cornell-box/scene-v4-nolight.pbrt` next to the scripts. All the tutorials use
  it. (The Cornell box is by Benedikt Bitterli, released under
  {download}`CC0 <scenes/cornell-box/LICENSE.txt>`.)

## Time-gated rendering

A time-gated image keeps only the light whose total path length (laser -> scene -> camera) falls
inside a gate.

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Time-gated rendering
:img-top: images/thumbnails/time_gated_offline_thumb.jpg
:img-alt: Time-gated Cornell box
:link: time_gated_offline
:link-type: doc

Render a time-gated image offline with `TimeGatedPathTracerInline` and save it.
```

```{grid-item-card} Online time-gated rendering
:img-top: images/thumbnails/time_gated_online_thumb.jpg
:img-alt: The time-gated Cornell box in its window
:link: time_gated_online
:link-type: doc

Show the same time-gated image in an interactive window.
```
````

## Transient rendering

A transient histogram records, for every pixel, how much light arrives at each path length, in
`timeBin` bins between `timeMin` and `timeMax`.

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Transient rendering
:img-top: images/thumbnails/transient_offline_thumb.jpg
:img-alt: Bins of the Cornell box's transient histogram
:link: transient_offline
:link-type: doc

Render a transient histogram offline with `TransientHistogramPathTracerInline` and save a grid of
its bins.
```

```{grid-item-card} Online transient rendering
:img-top: images/thumbnails/transient_online_thumb.jpg
:img-alt: The transient histogram window
:link: transient_online
:link-type: doc

Browse the histogram's bins in an interactive window and plot a pixel's transient profile.
```
````

```{toctree}
:hidden:

time_gated_offline
time_gated_online
transient_offline
transient_online
```
