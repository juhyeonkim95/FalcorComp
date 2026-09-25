# Installation

falcorcomp is distributed as binary wheels for Linux and Windows, for Python 3.9 to 3.13. A wheel
contains Falcor, its render passes and their shaders, so no separate Falcor build is needed.

## Requirements

- **Operating system:** 64-bit Linux or Windows. macOS is not supported.
  - Linux: x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or later).
  - Windows: Windows 10 (version 20H2 or later) or Windows 11.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver. falcorcomp
  renders with Vulkan on Linux and with Direct3D 12 on Windows.
- **Python:** 64-bit Python 3.9, 3.10, 3.11, 3.12 or 3.13.
  - Linux: the Python must include its shared library, for example `libpython3.12.so.1.0` for
    Python 3.12. Conda environments and most system Pythons include it; on Debian or Ubuntu,
    install it with `sudo apt install libpython3.X` for your version `3.X`.
  - Windows: Python from [python.org](https://www.python.org/downloads/windows/) or conda. The
    Microsoft Visual C++ Redistributable for Visual Studio 2015-2022 must be installed; most
    systems already have it.

## Installing with pip

We recommend installing into a fresh environment. With conda (any supported Python version works):

```bash
conda create -n falcorcomp python=3.12
conda activate falcorcomp
```

or with a virtual environment:

::::{tab-set}
:::{tab-item} Linux
:sync: linux

```bash
python3 -m venv falcorcomp-env
source falcorcomp-env/bin/activate
```
:::
:::{tab-item} Windows
:sync: windows

```bat
py -3.12 -m venv falcorcomp-env
falcorcomp-env\Scripts\activate
```
:::
::::

falcorcomp is currently published on TestPyPI. Its only dependency, NumPy, comes from PyPI:

```bash
pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ falcorcomp
```

pip picks the wheel for your operating system and Python version. To install a wheel file you
downloaded instead, choose the one whose name matches your Python version (`cp312` is Python 3.12):

::::{tab-set}
:::{tab-item} Linux
:sync: linux

```bash
pip install falcorcomp-0.1.2-cp312-cp312-manylinux_2_35_x86_64.whl
```
:::
:::{tab-item} Windows
:sync: windows

```bat
pip install falcorcomp-0.1.2-cp312-cp312-win_amd64.whl
```
:::
::::

## Verifying the installation

Creating a `Testbed` initializes the GPU device, so this checks the driver as well as the package:

```bash
python -c "import falcorcomp as falcor; falcor.Testbed(create_window=False); print('falcorcomp works')"
```

## Shader cache

Compiled shaders are cached per user, so the first run of a render pass is slower than later
ones:

- Linux: `~/.cache/falcorcomp/<version>/shadercache` (or under `$XDG_CACHE_HOME` when it is set)
- Windows: `%USERPROFILE%\.cache\falcorcomp\<version>\shadercache`

Set the environment variable `FALCOR_SHADER_CACHE_PATH` to use another directory, or to an empty
string to disable the cache.

## Building from source

Building the wheel yourself is only needed for development or for a Python version without a
wheel. It requires the build dependencies of [Falcor](https://github.com/NVIDIAGameWorks/Falcor)
and the CUDA toolkit. By default the build uses the Python that Falcor downloads (3.10); to build
for another version, add `-DFALCOR_USE_SYSTEM_PYTHON=ON` to the configure command and run it from
an environment with that Python.

::::{tab-set}
:::{tab-item} Linux
:sync: linux

```bash
# CMAKE_CUDA_COMPILER keeps CUDA enabled when nvcc is not on PATH; the policy minimum is needed with CMake 4.
cmake -S . -B build/GCC_11.3.0x86_64-linux-gnu-nogtk -DCMAKE_BUILD_TYPE=Release -DFALCOR_ENABLE_GTK=OFF \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/GCC_11.3.0x86_64-linux-gnu-nogtk -j
pip install auditwheel patchelf
python3 packaging/falcorcomp/build_wheel.py --build-dir build/GCC_11.3.0x86_64-linux-gnu-nogtk
pip install build/GCC_11.3.0x86_64-linux-gnu-nogtk/falcorcomp/dist/falcorcomp-*.whl
```
:::
:::{tab-item} Windows
:sync: windows

This needs Visual Studio 2022 with the "Desktop development with C++" workload and a Windows 10
or 11 SDK. Run these in the "x64 Native Tools Command Prompt for VS 2022":

```bat
setup.bat
tools\.packman\cmake\bin\cmake.exe --preset windows-ninja-msvc
tools\.packman\cmake\bin\cmake.exe --build build\windows-ninja-msvc --config Release
python packaging\falcorcomp\build_wheel.py --build-dir build\windows-ninja-msvc
```

Then install the wheel it writes to `build\windows-ninja-msvc\falcorcomp\dist\` with
`pip install <wheel file>`.
:::
::::

Run `build_wheel.py` with the same Python the build used: the wheel only works with that version.

## Troubleshooting

`ERROR: No matching distribution found for falcorcomp`
: There are wheels for Python 3.9 to 3.13 on 64-bit Linux (x86_64) and Windows. Check
  `python --version`, and that the Python is 64-bit.

`ImportError: falcorcomp needs libpython3.X.so.1.0` (Linux)
: The shared Python library is missing. Install it (`sudo apt install libpython3.X`) or use a
  conda environment.

`ImportError: DLL load failed` (Windows)
: Install the latest Microsoft Visual C++ Redistributable for Visual Studio 2015-2022 (x64), and
  update the NVIDIA driver.

The `Testbed` fails to create a device
: Update the NVIDIA driver. On Linux, check that Vulkan works (for example, with `vulkaninfo`); on
  Windows, check that the GPU supports DirectX 12 ray tracing (DXR 1.1).

## License

Falcor is licensed under the BSD 3-Clause license by NVIDIA. The wheel also bundles third-party
components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime,
RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
