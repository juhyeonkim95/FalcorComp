# Installation

falcorcomp is distributed as a binary wheel for Linux. It contains Falcor, its render passes and
their shaders, so no separate Falcor build is needed.

## Requirements

- **Operating system:** Linux x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or
  later). Windows and macOS are not supported.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver with Vulkan
  support.
- **Python:** 3.10, including its shared library `libpython3.10.so.1.0`. Conda environments and
  most system Pythons include it; on Debian or Ubuntu, install it with
  `sudo apt install libpython3.10`.

## Installing with pip

We recommend installing into a fresh environment:

```bash
conda create -n falcorcomp python=3.10
conda activate falcorcomp
```

or, with a system Python 3.10:

```bash
python3.10 -m venv falcorcomp-env
source falcorcomp-env/bin/activate
```

falcorcomp is currently published on TestPyPI. Its only dependency, NumPy, comes from PyPI:

```bash
pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ falcorcomp
```

To install a wheel file you downloaded instead:

```bash
pip install falcorcomp-0.1.0-cp310-cp310-manylinux_2_35_x86_64.whl
```

## Verifying the installation

Creating a `Testbed` initializes the GPU device, so this checks the driver as well as the package:

```bash
python -c "import falcorcomp as falcor; falcor.Testbed(create_window=False); print('falcorcomp works')"
```

## Building from source

Building the wheel yourself is only needed for development or for another Python version. It
requires the build dependencies of [Falcor](https://github.com/NVIDIAGameWorks/Falcor), the CUDA
toolkit, and the Python version the wheel is for.

```bash
# CMAKE_CUDA_COMPILER keeps CUDA enabled when nvcc is not on PATH; the policy minimum is needed with CMake 4.
cmake -S . -B build/GCC_11.3.0x86_64-linux-gnu-nogtk -DCMAKE_BUILD_TYPE=Release -DFALCOR_ENABLE_GTK=OFF \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/GCC_11.3.0x86_64-linux-gnu-nogtk -j
pip install auditwheel patchelf
python3 packaging/falcorcomp/build_wheel.py --build-dir build/GCC_11.3.0x86_64-linux-gnu-nogtk
pip install build/GCC_11.3.0x86_64-linux-gnu-nogtk/falcorcomp/dist/falcorcomp-*.whl
```

Run `build_wheel.py` with the same Python the build used: the wheel only works with that version.

## Troubleshooting

`ImportError: falcorcomp needs libpython3.10.so.1.0`
: The shared Python library is missing. Install it (`sudo apt install libpython3.10`) or use a
  conda environment.

`ERROR: No matching distribution found for falcorcomp`
: The wheel is built for Python 3.10 on Linux x86_64 only. Check `python --version`.

The `Testbed` fails to create a device
: Update the NVIDIA driver, and check that Vulkan works (for example, with `vulkaninfo`).

## License

Falcor is licensed under the BSD 3-Clause license by NVIDIA. The wheel also bundles third-party
components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime,
RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
