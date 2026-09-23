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

Configure a Release build without GTK (it is only used for dialogs), build it, and package it. The wheel is repaired into a manylinux wheel with auditwheel.

```bash
# CMAKE_CUDA_COMPILER keeps CUDA enabled when nvcc is not on PATH; the policy minimum is needed with CMake 4.
cmake -S . -B build/GCC_11.3.0x86_64-linux-gnu-nogtk -DCMAKE_BUILD_TYPE=Release -DFALCOR_ENABLE_GTK=OFF \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/GCC_11.3.0x86_64-linux-gnu-nogtk -j
pip install auditwheel patchelf
python3 packaging/falcorcomp/build_wheel.py --build-dir build/GCC_11.3.0x86_64-linux-gnu-nogtk
pip install build/GCC_11.3.0x86_64-linux-gnu-nogtk/falcorcomp/dist/falcorcomp-*.whl
```

Falcor is licensed under the BSD 3-Clause license by NVIDIA; see `LICENSE.md` in the package.
