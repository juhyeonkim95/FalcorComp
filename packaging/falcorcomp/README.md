# falcorcomp

Falcor with time-of-flight render passes from *ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling* (SIGGRAPH 2026).

```python
import falcorcomp as falcor
testbed = falcor.Testbed(create_window=False)
```

Included render passes: `TimeGatedPathTracerInline`, `TimeGatedReSTIRInline`, `TransientHistogramPathTracerInline`, plus `VBufferRT`/`LaserVBufferRT`, `AccumulatePass` and `ToneMapper`. Scene importers: pbrt, pyscene, Mitsuba, Assimp.

## Requirements

- Linux x86_64 with an NVIDIA GPU that supports ray tracing, and a recent driver with Vulkan.
- The Python version the wheel was built for, with its shared library (`libpython3.x.so.1.0`).

## Building the wheel

From a Release build of this repository:

```bash
python3 packaging/falcorcomp/build_wheel.py --build-dir build/GCC_11.3.0x86_64-linux-gnu
pip install build/GCC_11.3.0x86_64-linux-gnu/falcorcomp/dist/falcorcomp-*.whl
```

Falcor is licensed under the BSD 3-Clause license by NVIDIA; see `LICENSE.md` in the package.
