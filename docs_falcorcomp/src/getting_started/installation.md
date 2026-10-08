# Installation

falcorcomp is distributed as binary wheels for 64-bit Linux and Windows, for Python 3.9 to 3.13.
A wheel contains Falcor, its render passes and their shaders, so no separate Falcor build is needed.

## Requirements

- **Operating system:** 64-bit Linux: x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or
  later); or 64-bit Windows 11 (Windows 10 is untested). macOS is not supported.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver. falcorcomp
  renders with Vulkan on Linux, and with Direct3D 12 on Windows, where Vulkan also works:
  `falcor.Testbed(device_type=falcor.DeviceType.Vulkan)`.
- **Python:** 64-bit Python 3.9, 3.10, 3.11, 3.12 or 3.13. On Linux, also its shared library, for
  example `libpython3.12.so.1.0` for Python 3.12. Conda environments and most system Pythons include
  it; on Debian or Ubuntu, install it with `sudo apt install libpython3.X` for your version `3.X`.

## Installing with pip

We recommend installing into a fresh environment. With conda (any supported Python version works):

```bash
conda create -n falcorcomp python=3.12
conda activate falcorcomp
```

or with a virtual environment:

```bash
python3 -m venv falcorcomp-env
source falcorcomp-env/bin/activate  # On Windows: falcorcomp-env\Scripts\activate
```

Install falcorcomp from PyPI; pip also installs its only dependency, NumPy:

```bash
pip install falcorcomp
```

pip picks the wheel for your Python version and operating system. To install a wheel file you
downloaded instead, choose the one whose name matches both (`cp312` is Python 3.12; `manylinux` is
Linux, `win_amd64` is Windows):

```bash
pip install falcorcomp-0.2.1-cp312-cp312-manylinux_2_35_x86_64.whl
```

## Verifying the installation

Creating a `Testbed` initializes the GPU device, so this checks the driver as well as the package:

```bash
python -c "import falcorcomp as falcor; falcor.Testbed(create_window=False); print('falcorcomp works')"
```

## Shader cache

Compiled shaders are cached per user, so the first run of a render pass is slower than later ones:
in `~/.cache/falcorcomp/<version>/shadercache` on Linux (under `$XDG_CACHE_HOME` when it is set),
and in `%LOCALAPPDATA%\falcorcomp\<version>\shadercache` on Windows.

Set the environment variable `FALCOR_SHADER_CACHE_PATH` to use another directory, or to an empty
string to disable the cache.

## What the package leaves out

The package contains every falcorcomp render pass, plus Falcor's `PathTracer`, `SVGFPass` and the passes the
tutorials use. Two things work only in a [build from source](#building-from-source), for license reasons:

- `PathTracer`'s `useRTXDI` option: the RTXDI SDK's shaders may not be redistributed in source form.
- `OptixDenoiser`: the OptiX SDK license requires an agreement with every recipient.

(building-from-source)=
## Building from source

Building the wheel yourself is only needed for development or for a Python version without a
wheel. It requires the build dependencies of [Falcor](https://github.com/NVIDIAGameWorks/Falcor)
and the CUDA toolkit.

```bash
# CMAKE_CUDA_COMPILER keeps CUDA enabled when nvcc is not on PATH; the policy minimum is needed with CMake 4.
cmake -S . -B build/GCC_11.3.0x86_64-linux-gnu-nogtk -DCMAKE_BUILD_TYPE=Release -DFALCOR_ENABLE_GTK=OFF \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/GCC_11.3.0x86_64-linux-gnu-nogtk -j
pip install auditwheel patchelf
python3 packaging/falcorcomp/build_wheel.py --build-dir build/GCC_11.3.0x86_64-linux-gnu-nogtk
pip install build/GCC_11.3.0x86_64-linux-gnu-nogtk/falcorcomp/dist/falcorcomp-*.whl
```

On Windows, `packaging/falcorcomp/build_windows_wheels.py` builds, packages and tests the wheel for
each Python version: it needs Visual Studio 2022 with the C++ tools, git and conda, and runs from the
Anaconda Prompt (see the script's header).

The default build uses Falcor's bundled Python 3.10. To build for another Python version, add
`-DFALCOR_USE_SYSTEM_PYTHON=ON -DPython_EXECUTABLE=/path/to/python3.X` to the `cmake -S` command,
use a separate build directory, and run `build_wheel.py` with that interpreter. In general, run
`build_wheel.py` with the same Python the build used: the wheel only works with that version.

### Tests

The render passes come with regression tests in `Source/RenderPasses/<Pass>/tests/`. All but
`TimeGatedReSTIRInline/tests/test_paired_shift_math.py`, which checks the shift equations in NumPy,
render on the GPU. Continuous integration builds the source and runs only that NumPy test: run the
GPU tests yourself after a change to the passes. From the repository root, with a source build:

```bash
source build/linux-gcc/bin/Release/setpath.sh  # Or your build's bin/setpath.sh.
python Source/RenderPasses/TimeGatedReSTIRInline/tests/test_initial_sampling.py
```

The tests render the tutorial Cornell box in `docs_falcorcomp/src/tutorials/scenes/`.
`test_surface_reuse.py` also renders the Cornell box with the dragon, and skips it without the dragon
mesh (`meshes/dragon.ply` next to its `.pbrt` file, not in the repository).

## Troubleshooting

`ERROR: No matching distribution found for falcorcomp`
: There are wheels for Python 3.9 to 3.13 on 64-bit Linux (x86_64) and Windows only. Check
  `python --version`, and that the Python is 64-bit.

`ImportError: falcorcomp needs libpython3.X.so.1.0`
: The shared Python library is missing. Install it (`sudo apt install libpython3.X`) or use a
  conda environment.

The `Testbed` fails to create a device
: Update the NVIDIA driver. On Linux, check that Vulkan works (for example, with `vulkaninfo`); on
  Windows, try Vulkan instead of Direct3D 12: `falcor.Testbed(device_type=falcor.DeviceType.Vulkan)`.

## License

Falcor is licensed under the BSD 3-Clause license by NVIDIA. The wheel also bundles third-party
components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime,
RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
