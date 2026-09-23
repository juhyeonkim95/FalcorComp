# Third-party notices

falcorcomp is based on NVIDIA Falcor, which is licensed under the BSD 3-Clause license (`LICENSE.md`). The package also contains or links the third-party components below. Each component's license text is in `third_party_licenses/<file>`.

## Components under NVIDIA proprietary licenses

These components are not covered by the BSD license. They are redistributed under, and their use is governed by, the NVIDIA license terms listed below.

| Component | Version | How it is included | License | File |
|---|---|---|---|---|
| NVIDIA Texture Tools (NVTT) | 3.1.6 | `libnvtt.so` | NVIDIA Texture Tools SDK license | `NVTT.txt` |
| CUDA runtime | 11.x | `libcudart.so.11.0`, shipped with NVTT | NVIDIA CUDA Toolkit EULA, https://docs.nvidia.com/cuda/eula/ | |
| RTXDI | 1.3.0 | compiled into `libFalcor.so` | NVIDIA RTX SDKs license | `RTXDI.txt` |

This software contains source code provided by NVIDIA Corporation.

## Shared libraries bundled in the package

| Component | Version | Library | License | File |
|---|---|---|---|---|
| Open Asset Import Library (assimp) | 5.2.5 | `libassimp.so.5` | BSD-3-Clause | `assimp.txt` |
| Blosc | 1.18.1 | `libblosc.so.1` | BSD-3-Clause | `blosc.txt` |
| FreeImage | 3.18.0 | `libFreeImage.so` | FreeImage Public License 1.0 (chosen from FIPL or GPL) | `FreeImage.txt` |
| OpenEXR | 3.1.5 | `libOpenEXR`, `libIex`, `libIlmThread` | BSD-3-Clause | `OpenEXR.txt` |
| Imath | 3.1.5 | compiled into OpenEXR | BSD-3-Clause | `Imath.txt` |
| OpenVDB | 9.0.0 | `libopenvdb.so.9.0`, `shaders/nanovdb/PNanoVDB.h` | MPL-2.0 | `OpenVDB.txt` |
| Slang, slang-gfx | 2024.1.34 | `libslang.so`, `libgfx.so`, `libslang-glslang.so` | MIT | `Slang.txt` |
| glslang | slang fork | `libslang-glslang.so` | BSD-3-Clause and others (see file) | `glslang.txt` |
| SPIRV-Tools | slang fork | `libslang-glslang.so` | Apache-2.0 | `SPIRV-Tools.txt` |
| SPIRV-Headers | | Slang | MIT-style Khronos license | `SPIRV-Headers.txt` |
| miniz | | Slang | MIT | `miniz.txt` |
| unordered_dense | | Slang | MIT | `unordered_dense.txt` |
| Threading Building Blocks | 2020.3 | `libtbb.so.2`, `libtbbmalloc.so.2` | Apache-2.0 | `TBB.txt` |

## Libraries statically linked into the bundled libraries or libFalcor

| Component | License | File |
|---|---|---|
| args | MIT | `args.txt` |
| backward-cpp | MIT | `backward-cpp.txt` |
| Boost (1.80.0) and fstd (Boost license) | BSL-1.0 | `boost.txt` |
| BS::thread_pool | MIT | `BS_thread_pool.txt` |
| bzip2 | bzip2 license (BSD-style) | `bzip2.txt` |
| DDSHeader (Microsoft DirectXTex) | MIT | `DDSHeader.txt` |
| Draco | Apache-2.0 | `draco.txt` |
| fast_float | MIT (chosen from Apache-2.0 or MIT) | `fast_float.txt` |
| {fmt} | MIT | `fmt.txt` |
| GLFW | Zlib | `GLFW.txt` |
| Dear ImGui | MIT | `imgui.txt` |
| imguinodegrapheditor (Flix01/imgui addons) | MIT | `imgui-addons.txt` |
| JasPer | JasPer License 2.0 | `jasper.txt` |
| jxrlib | BSD-2-Clause | `jxrlib.txt` |
| kuba zip | Unlicense | `kubazip.txt` |
| Little CMS | MIT | `lcms.txt` |
| libjpeg-turbo | IJG and BSD-3-Clause | `libjpeg-turbo.txt` |
| liblzma (XZ Utils) | public domain | `liblzma.txt` |
| libpng | PNG Reference Library License v2 | `libpng.txt` |
| LibRaw (201903) | CDDL-1.0 (chosen from LGPL-2.1 or CDDL-1.0) | `LibRaw.txt` |
| libtiff | libtiff license | `libtiff.txt` |
| libwebp | BSD-3-Clause | `libwebp.txt` |
| LZ4 | BSD-2-Clause | `lz4.txt` |
| lz4_stream | BSD-3-Clause | `lz4_stream.txt` |
| mikktspace | Zlib | `mikktspace.txt` |
| MiniZip | Zlib | `minizip.txt` |
| nlohmann/json | MIT | `nlohmann-json.txt` |
| OpenJPEG | BSD-2-Clause | `openjpeg.txt` |
| OpenSubdiv | Modified Apache-2.0 | `OpenSubdiv.txt` |
| poly2tri | BSD-3-Clause | `poly2tri.txt` |
| pugixml | MIT | `pugixml.txt` |
| pybind11 | BSD-3-Clause | `pybind11.txt` |
| pybind11_json | BSD-3-Clause | `pybind11_json.txt` |
| RapidJSON | MIT | `rapidjson.txt` |
| sigs | MIT | `sigs.txt` |
| Snappy | BSD-3-Clause | `snappy.txt` |
| stb | MIT (chosen from MIT or public domain) | `stb.txt` |
| UTF8-CPP | BSL-1.0 | `utfcpp.txt` |
| Vulkan-Headers | Apache-2.0 | `Vulkan-Headers.txt` |
| zlib | Zlib | `zlib.txt` |
| Zstandard | BSD-3-Clause (chosen from BSD or GPL-2.0) | `zstd.txt` |

## Fonts

DejaVu Sans Bold and DejaVu Sans Mono (`data/framework/fonts/`) use the Bitstream Vera license. DejaVu's changes are in the public domain. See `data/framework/fonts/DejaVu-LICENSE.txt`.

## Source code for weak-copyleft components

OpenVDB (MPL-2.0), FreeImage (FIPL 1.0) and LibRaw (CDDL-1.0) are distributed in executable form. Their source code is available here:

- OpenVDB 9.0.0: https://github.com/AcademySoftwareFoundation/openvdb/tree/v9.0.0
- FreeImage 3.18.0: https://freeimage.sourceforge.io/download.html. The build applies vcpkg's patches from https://github.com/microsoft/vcpkg/tree/master/ports/freeimage.
- LibRaw 201903 snapshot: https://github.com/LibRaw/LibRaw
