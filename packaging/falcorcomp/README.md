# FalcorComp

FalcorComp is a GPU renderer for computational imaging, built on NVIDIA's [Falcor](https://github.com/NVIDIAGameWorks/Falcor) rendering framework. It adds render passes that simulate imaging systems beyond conventional cameras, and it is installed and used as the Python package `falcorcomp`.

The current release covers time-of-flight imaging: time-gated and transient rendering, including the methods from *ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling* (SIGGRAPH 2026). More computational imaging applications will be added in future releases.

The package is a binary wheel for Linux. It contains Falcor, the render passes and their shaders, so no separate Falcor build is needed.

```python
import falcorcomp as falcor
testbed = falcor.Testbed(create_window=False)
```

## Render passes

| Application | Render passes |
|---|---|
| Time-gated rendering | `TimeGatedPathTracerInline`, `TimeGatedReSTIRInline` |
| Transient rendering | `TransientHistogramPathTracerInline`, `TransientHistogramReSTIRInline` |
| Utilities | `VBufferRT`/`LaserVBufferRT`, `AccumulatePass`, `ToneMapper`, `TransientHistogramViewer`, `LaserPositionViewer` |

Scene importers: pbrt, pyscene, Mitsuba, Assimp.

## Requirements

- **Operating system:** Linux x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or later). Windows and macOS are not supported.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver with Vulkan support.
- **Python:** 3.9 to 3.13, including its shared library (for example, `libpython3.10.so.1.0` for Python 3.10). Conda environments and most system Pythons include it; on Debian or Ubuntu, install it with `sudo apt install libpython3.X` for your version `3.X`.

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

FalcorComp is based on Falcor, which is licensed under the BSD 3-Clause license by NVIDIA (`LICENSE.md`). The wheel also bundles third-party components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime, RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
