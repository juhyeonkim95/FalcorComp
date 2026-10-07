# Installation

falcorcomp is distributed as binary wheels for 64-bit Linux, for Python 3.9 to 3.13. A wheel
contains Falcor, its render passes and their shaders, so no separate Falcor build is needed.
Windows wheels are not available yet.

## Requirements

- **Operating system:** 64-bit Linux: x86_64 with glibc 2.35 or newer (for example, Ubuntu 22.04 or
  later). Windows is not supported yet, and macOS is not supported.
- **GPU:** an NVIDIA GPU with hardware ray tracing (RTX), and a recent NVIDIA driver. falcorcomp
  renders with Vulkan.
- **Python:** 64-bit Python 3.9, 3.10, 3.11, 3.12 or 3.13, with its shared library, for example
  `libpython3.12.so.1.0` for Python 3.12. Conda environments and most system Pythons include it; on
  Debian or Ubuntu, install it with `sudo apt install libpython3.X` for your version `3.X`.

## Installing with pip

We recommend installing into a fresh environment. With conda (any supported Python version works):

```bash
conda create -n falcorcomp python=3.12
conda activate falcorcomp
```

or with a virtual environment:

```bash
python3 -m venv falcorcomp-env
source falcorcomp-env/bin/activate
```

falcorcomp is currently published on TestPyPI. Its only dependency, NumPy, comes from PyPI:

```bash
pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ falcorcomp
```

pip picks the wheel for your Python version. To install a wheel file you downloaded instead,
choose the one whose name matches your Python version (`cp312` is Python 3.12):

```bash
pip install falcorcomp-0.1.4-cp312-cp312-manylinux_2_35_x86_64.whl
```

## Verifying the installation

Creating a `Testbed` initializes the GPU device, so this checks the driver as well as the package:

```bash
python -c "import falcorcomp as falcor; falcor.Testbed(create_window=False); print('falcorcomp works')"
```

## Shader cache

Compiled shaders are cached per user, in `~/.cache/falcorcomp/<version>/shadercache` (under
`$XDG_CACHE_HOME` when it is set), so the first run of a render pass is slower than later ones.

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
and the CUDA toolkit. By default the build uses the Python that Falcor downloads (3.10); to build
for another version, add `-DFALCOR_USE_SYSTEM_PYTHON=ON` to the configure command and run it from
an environment with that Python.

```bash
# CMAKE_CUDA_COMPILER keeps CUDA enabled when nvcc is not on PATH; the policy minimum is needed with CMake 4.
cmake -S . -B build/GCC_11.3.0x86_64-linux-gnu-nogtk -DCMAKE_BUILD_TYPE=Release -DFALCOR_ENABLE_GTK=OFF \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/GCC_11.3.0x86_64-linux-gnu-nogtk -j
pip install auditwheel patchelf
python3 packaging/falcorcomp/build_wheel.py --build-dir build/GCC_11.3.0x86_64-linux-gnu-nogtk
pip install build/GCC_11.3.0x86_64-linux-gnu-nogtk/falcorcomp/dist/falcorcomp-*.whl
```

The wheel can be built only on Linux so far: `build_wheel.py` does not support Windows yet.

Run `build_wheel.py` with the same Python the build used: the wheel only works with that version.

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
: There are wheels for Python 3.9 to 3.13 on 64-bit Linux (x86_64) only. Check `python --version`,
  and that the Python is 64-bit.

`ImportError: falcorcomp needs libpython3.X.so.1.0`
: The shared Python library is missing. Install it (`sudo apt install libpython3.X`) or use a
  conda environment.

The `Testbed` fails to create a device
: Update the NVIDIA driver, and check that Vulkan works (for example, with `vulkaninfo`).

## License

Falcor is licensed under the BSD 3-Clause license by NVIDIA. The wheel also bundles third-party
components under their own licenses, including NVIDIA proprietary ones (NVTT, the CUDA runtime,
RTXDI); see `THIRD_PARTY_NOTICES.md` and `third_party_licenses/` in the installed package.
