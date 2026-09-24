# falcorcomp

Falcor with time-of-flight render passes from *ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling* (SIGGRAPH 2026).

falcorcomp is distributed as a binary wheel for Linux. It contains Falcor, its render passes and their shaders, so no separate Falcor build is needed.

```python
import falcorcomp as falcor
testbed = falcor.Testbed(create_window=False)
```

Included render passes:

- **Time-gated rendering:** `TimeGatedPathTracerInline`, `TimeGatedReSTIRInline`
- **Transient rendering:** `TransientHistogramPathTracerInline`, `TransientHistogramReSTIRInline`
- **Utility:** `VBufferRT`/`LaserVBufferRT`, `AccumulatePass`, `ToneMapper`, `TransientHistogramViewer`, `LaserPositionViewer`

Scene importers: pbrt, pyscene, Mitsuba, Assimp.

## Requirements

- **Operating system:** Linux x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or later). Windows and macOS are not supported.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver with Vulkan support.
- **Python:** 3.9 or 3.10, including its shared library (`libpython3.10.so.1.0` for Python 3.10). Conda environments and most system Pythons include it; on Debian or Ubuntu, install it with `sudo apt install libpython3.10` (or `libpython3.9`). Python 3.11 and newer are not supported yet, because Falcor uses pybind11 2.9.

## Installation

falcorcomp is currently published on TestPyPI. Its only dependency, NumPy, comes from PyPI:

```bash
pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ falcorcomp
```

Creating a `Testbed` initializes the GPU device, so this checks the driver as well as the package:

```bash
python -c "import falcorcomp as falcor; falcor.Testbed(create_window=False); print('falcorcomp works')"
```

Compiled shaders are cached in `~/.cache/falcorcomp/`. Set `FALCOR_SHADER_CACHE_PATH` to use another directory, or to an empty string to disable the cache.

## License

Falcor is licensed under the BSD 3-Clause license by NVIDIA (`LICENSE.md`). The wheel also bundles third-party components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime, RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
