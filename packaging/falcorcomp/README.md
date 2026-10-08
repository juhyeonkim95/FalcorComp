# FalcorComp

FalcorComp is a GPU renderer for computational imaging, built on NVIDIA's [Falcor](https://github.com/NVIDIAGameWorks/Falcor) rendering framework. It adds render passes that simulate imaging systems beyond conventional cameras — time-of-flight, modulated light, Doppler sensing and event cameras — and it is installed and used as the Python package `falcorcomp`. All renderers run on the GPU with hardware ray tracing, for interactive as well as offline simulation.

The package is a binary wheel for Linux and Windows. It contains Falcor, the render passes and their shaders, so no separate Falcor build is needed.

![The Cornell box rendered as a standard image, a time-gated image, a transient histogram, CW-ToF and structured-light measurements, a Doppler spectrum, a Doppler-gated image, a Doppler ToF velocity map and camera events](https://raw.githubusercontent.com/juhyeonkim95/FalcorComp/master/docs_falcorcomp/src/getting_started/images/overview_outputs.jpg)

```python
import falcorcomp as falcor
testbed = falcor.Testbed(create_window=False)
```

Documentation, tutorials and the reference of every render pass: [falcorcomp.readthedocs.io](https://falcorcomp.readthedocs.io/en/latest/).

## Render passes

| Application | Render passes |
|---|---|
| Time-gated rendering | `TimeGatedPathTracerInline`, `TimeGatedReSTIRInline` |
| Transient rendering | `TransientHistogramPathTracerInline`, `TransientHistogramReSTIRInline` |
| Continuous-wave ToF | `CWToFPathTracerInline` |
| Structured light | `StructuredLightPathTracerInline` |
| Doppler (optical heterodyne detection) | `DopplerGatedPathTracerInline`, `DopplerHistogramPathTracerInline` |
| Doppler ToF | `DopplerToFPathTracerInline`, `VelocityGroundTruthInline` (ground-truth velocity) |
| Event cameras | `EventDifference`, `EventSVGF`, `EventGenerator`, with Falcor's `PathTracer` and `SVGFPass` |
| Utilities | `LaserLight`, `InlinePathTracer`, `VBufferRT`/`GBufferRT`, `AccumulatePass`, `TransientHistogramAccumulatePass`, `ToneMapper`, `TransientHistogramViewer`, `LaserPositionViewer`, `SplitScreenPass` |

Scene importers: pbrt, pyscene, Mitsuba, Assimp.

Not in the package, for license reasons: `PathTracer`'s `useRTXDI` option (the RTXDI SDK's shaders cannot be redistributed in source form) and `OptixDenoiser` (the OptiX SDK license). Both work in a build from source.

## Research

FalcorComp includes the implementations of these papers:

- **ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling**, SIGGRAPH 2026 (ACM TOG). [Project page](https://juhyeonkim95.github.io/project-pages/tof_restir/)
- **Difference-aware Filtering for Event Camera Simulation**, EGSR 2026 (Computer Graphics Forum). [Project page](https://juhyeonkim95.github.io/project-pages/event_svgf/)
- **Geometric Antithetic Sampling for Spatiotemporally Modulated Light**, SIGGRAPH Asia 2026.
- **A Monte Carlo Rendering Framework for Simulating Optical Heterodyne Detection**, SIGGRAPH 2025 (ACM TOG), honorable mention. [Project page](https://juhyeonkim95.github.io/project-pages/ohd_rendering/)
- **Doppler Time-of-Flight Rendering**, SIGGRAPH Asia 2023 (ACM TOG). [Project page](https://juhyeonkim95.github.io/project-pages/dopplertof/)

The BibTeX entries are in the [README on GitHub](https://github.com/juhyeonkim95/FalcorComp#citation).

## Requirements

- **Operating system:** Linux x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or later), or 64-bit Windows 11 (Windows 10 is untested). macOS is not supported.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver. falcorcomp renders with Vulkan on Linux, and with Direct3D 12 on Windows, where Vulkan also works: `falcor.Testbed(device_type=falcor.DeviceType.Vulkan)`.
- **Python:** 64-bit Python 3.9 to 3.13. On Linux, also its shared library (for example, `libpython3.10.so.1.0` for Python 3.10). Conda environments and most system Pythons include it; on Debian or Ubuntu, install it with `sudo apt install libpython3.X` for your version `3.X`.

## Installation

```bash
pip install falcorcomp
```

Creating a `Testbed` initializes the GPU device, so this checks the driver as well as the package:

```bash
python -c "import falcorcomp as falcor; falcor.Testbed(create_window=False); print('falcorcomp works')"
```

Compiled shaders are cached in `~/.cache/falcorcomp/` on Linux and in `%LOCALAPPDATA%\falcorcomp\` on Windows. Set `FALCOR_SHADER_CACHE_PATH` to use another directory, or to an empty string to disable the cache.

## License

FalcorComp is based on Falcor, which is licensed under the BSD 3-Clause license by NVIDIA (`LICENSE.md`). The wheel also bundles third-party components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime, RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
