# pybind11 in Falcor

This is pybind11 v2.13.6 (https://github.com/pybind/pybind11/tree/v2.13.6, commit a2e59f0),
copied into the repository with only the files needed to build: `CMakeLists.txt`, `include/`,
`tools/`, `LICENSE` and `README.rst`.

Falcor's change: enum values print as `Type.Value` instead of `<Type.Value: 1>`, because Falcor
generates Python scripts from `repr()` when it serializes render graphs and scenes. See the
comment in `enum_base::init` in `include/pybind11/pybind11.h`.

Upstream Falcor uses pybind11 v2.9.2 with the same change, which only supports Python up to 3.10.
v2.13.6 supports Python 3.7 to 3.13.
