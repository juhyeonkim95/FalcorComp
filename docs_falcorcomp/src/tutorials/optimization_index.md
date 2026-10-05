# Optimization

These pages explain two choices that make falcorcomp's render passes fast, with scripts that measure them on your
GPU.

- [Inline ray tracing](inline_ray_tracing.md): why every falcorcomp pass traces its rays inline, from compute
  shaders, rather than with the ray tracing pipeline.
- [Splitting the ReSTIR passes](restir_pass_split.md): how the path-length-aware ReSTIR passes split spatial and
  temporal reuse into two kernels each, to keep the shift mapping fast.

```{toctree}
:hidden:

inline_ray_tracing
restir_pass_split
```
