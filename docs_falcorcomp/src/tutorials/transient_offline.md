# Transient rendering

This tutorial renders a transient histogram of the Cornell box offline with
`TransientHistogramPathTracerInline`. For every pixel, the histogram records how much light
arrives at each total path length (laser -> scene -> camera), in `timeBin` bins from `timeMin` to
`timeMax`. The image below shows 16 of the 64 bins, in reading order.

```{image} images/transient_offline.jpg
:alt: 16 bins of the Cornell box's transient histogram
:width: 512px
:align: center
```

## 1. Load the scene

```{literalinclude} code/transient_offline.py
:language: python
:start-after: "# 1. Load the scene"
:end-before: "# 2. Build the render graph"
```

## 2. Build the render graph

The tracer writes the histogram to its `histogram` output, a width x height x bins texture. It
adds every frame to the histogram, so no `AccumulatePass` is needed.

```{literalinclude} code/transient_offline.py
:language: python
:start-after: "# 2. Build the render graph"
:end-before: "# 3. Render"
```

## 3. Render

```{literalinclude} code/transient_offline.py
:language: python
:start-after: "# 3. Render"
:end-before: "# 4. Read the histogram"
```

## 4. Read the histogram

`to_numpy()` returns the histogram as bins x height x width x RGBA. Divided by the number of
frames, each bin holds the radiance per unit path length.

```{literalinclude} code/transient_offline.py
:language: python
:start-after: "# 4. Read the histogram"
:end-before: "# 5. Show 16 bins in a 4 x 4 grid"
```

## 5. Show 16 bins in a 4 x 4 grid

The 16 bins are spread evenly over the histogram. Each is scaled by the histogram range, so a
bin is as bright as the whole image would be if all of a pixel's light arrived in it.

```{literalinclude} code/transient_offline.py
:language: python
:start-after: "# 5. Show 16 bins in a 4 x 4 grid"
```

The full script: {download}`transient_offline.py <code/transient_offline.py>`.
