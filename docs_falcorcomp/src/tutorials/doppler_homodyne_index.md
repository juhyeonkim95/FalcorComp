# Doppler rendering with homodyne detection

The [Doppler rendering](doppler_index.md) tutorials render what optical heterodyne detection measures: the light
mixed with a local oscillator, whose beat frequencies are the Doppler shifts. Without a local oscillator, a detector
measures the intensity alone, and the scattered light beats with itself: homodyne detection. Its spectrum follows
from the same Doppler spectrum, the output of `DopplerHistogramPathTracerInline`, so it needs no other render pass.

These tutorials use the scene of [Doppler rendering](doppler_index.md), and their scripts plot with matplotlib
(`pip install matplotlib`).

````{grid} 1 2 2 2
:gutter: 3

```{grid-item-card} Speckle contrast imaging (LSCI, offline)
:img-top: images/thumbnails/speckle_contrast_thumb.jpg
:img-alt: Speckle contrast of the Cornell box with a moving and a rotating box, at a 1 ms exposure
:link: speckle_contrast_offline
:link-type: doc

Compute the speckle contrast of laser speckle contrast imaging from the Doppler spectrum, for exposures from 1 µs to
10 ms, and see the static light keep its contrast.
```
````

```{toctree}
:hidden:

speckle_contrast_offline
```
