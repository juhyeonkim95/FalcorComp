#!/usr/bin/env python3
"""Build the falcorcomp wheel from an existing Falcor build (Linux or Windows).

The package directory becomes Falcor's runtime directory: Falcor resolves
plugins/, shaders/, data/ and settings.json relative to libFalcor.so (Falcor.dll),
so the libraries only have to sit next to each other.

    python3 packaging/falcorcomp/build_wheel.py [--build-dir build/GCC_11.3.0x86_64-linux-gnu-nogtk]
    python packaging/falcorcomp/build_wheel.py [--build-dir build/windows-ninja-msvc]

Run it with the Python the build used (-DFALCOR_USE_SYSTEM_PYTHON=ON). The wheel
is written to <build-dir>/falcorcomp/dist/.

Linux: the built binaries already use $ORIGIN runpaths. The wheel is repaired
into a manylinux wheel with auditwheel, which bundles the remaining system
libraries; this needs `auditwheel` and `patchelf` on PATH and a build configured
with -DFALCOR_ENABLE_GTK=OFF.

Windows: the DLLs are found from the import tables (this needs `pefile`); the
package's __init__.py adds its directory to the DLL search path. The Microsoft
C++ runtime is bundled from the Visual Studio redistributable folder (run from a
developer prompt, which sets VCToolsRedistDir) or from System32.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

PACKAGE = "falcorcomp"
WINDOWS = sys.platform == "win32"
HERE = Path(__file__).resolve().parent
# The version is defined once, as __version__ in the package's __init__.py.
VERSION = re.search(r'^__version__ = "(.+)"$', (HERE / PACKAGE / "__init__.py").read_text(encoding="utf-8"),
                    re.M).group(1)
REPO = HERE.parents[1]
CORE_LIBRARY = "Falcor.dll" if WINDOWS else "libFalcor.so"
LIBRARY_SUFFIX = ".dll" if WINDOWS else ".so"
# The extension module built for the running Python, e.g. falcor_ext.cpython-310-x86_64-linux-gnu.so or
# falcor_ext.cp310-win_amd64.pyd.
EXTENSION = "falcor_ext" + sysconfig.get_config_var("EXT_SUFFIX")

# Render passes and scene importers shipped in the package.
PLUGINS = [
    # ToF render passes.
    "TimeGatedPathTracerInline",
    "TimeGatedReSTIRInline",
    "TransientHistogramPathTracerInline",
    "TransientHistogramReSTIRInline",
    "InlinePathTracer",
    # Modulated light.
    "CWToFPathTracerInline",
    "StructuredLightPathTracerInline",
    # Doppler.
    "DopplerHistogramPathTracerInline",
    "DopplerGatedPathTracerInline",
    "DopplerToFPathTracerInline",
    "VelocityGroundTruthInline",
    # Event cameras (EventDifference, EventSVGF, EventGenerator), with Falcor's path tracer and SVGF, which the event
    # tutorials use. OptixDenoiser is left out: the OptiX SDK license requires agreements with every recipient.
    "EventCamera",
    "PathTracer",
    "SVGFPass",
    # Passes used by the render graphs (the light, VBufferRT/GBufferRT, accumulation, tone mapping, split screen).
    "LaserLight",
    "GBuffer",
    "AccumulatePass",
    "TransientHistogramAccumulatePass",
    "ToneMapper",
    "DebugPasses",
    # Viewers for transient histograms and the laser spot.
    "TransientHistogramViewer",
    "LaserPositionViewer",
    # Scene importers (.pbrt, .pyscene, .xml, and meshes via Assimp).
    "PBRTImporter",
    "PythonImporter",
    "MitsubaImporter",
    "AssimpImporter",
]
# Shader folders under shaders/RenderPasses for the plugins above (and what they import).
RENDER_PASS_SHADERS = [
    "TimeGatedPathTracerInline", "TimeGatedReSTIRInline", "TransientHistogramPathTracerInline",
    "TransientHistogramReSTIRInline", "InlinePathTracer", "CWToFPathTracerInline", "StructuredLightPathTracerInline",
    "DopplerHistogramPathTracerInline", "DopplerGatedPathTracerInline", "DopplerToFPathTracerInline",
    "VelocityGroundTruthInline", "EventCamera", "PathTracer", "SVGFPass", "Shared", "GBuffer",
    "AccumulatePass", "TransientHistogramAccumulatePass", "ToneMapper", "DebugPasses", "TransientHistogramViewer",
    "LaserPositionViewer",
]
# Shader folders (relative to shaders/) left out of the package: render passes are added selectively,
# tests and samples are unused, RTXDI may only be redistributed as compiled code, and NRD (Windows) is only used
# by NRDPass.
EXCLUDED_SHADERS = {"RenderPasses", "Samples", "Tests", "Testing", "rtxdi", "Rendering/RTXDI", "nrd"}
# Falcor's own (BSD) RTXDI wrapper, shipped without the RTXDI SDK: PathTracer imports it, and without useRTXDI it
# compiles with RTXDI_INSTALLED = 0, which leaves out every SDK include. useRTXDI is therefore not available.
RTXDI_WRAPPER_SHADERS = ["Rendering/RTXDI/RTXDI.slang", "Rendering/RTXDI/PackedTypes.slang"]
DATA_FOLDERS = ["framework"]
# Libraries loaded with dlopen() at runtime, which ldd cannot see.
DLOPEN_LIBRARIES = ["libslang-glslang.so", "libtbbmalloc.so.2"]
# Windows: DLLs that Slang and DXC load with LoadLibrary at runtime, which the import tables do not list.
WINDOWS_DLOPEN_LIBRARIES = ["dxcompiler.dll", "dxil.dll", "slang-glslang.dll"]
# The Microsoft C++ runtime, bundled next to Falcor.dll ("app-local"): Python itself ships only vcruntime140*.dll, and
# DLLs built with a recent MSVC need a msvcp140.dll at least as new as the compiler.
MSVC_RUNTIME = re.compile(r"(msvcp140.*|vcruntime140.*|concrt140)\.dll$", re.I)

# Python versions that falcorcomp wheels are built for (pybind11 v2.13.6 supports up to 3.13).
PYTHON_REQUIRES = ">=3.9,<3.14"
# System libraries that auditwheel must not bundle: the NVIDIA driver, and the user's libpython.
REPAIR_EXCLUDES = ["libcuda.so.1", f"libpython{sys.version_info[0]}.{sys.version_info[1]}.so.1.0"]


def run(command, **kwargs):
    print("+", " ".join(str(c) for c in command), flush=True)
    return subprocess.run(command, check=True, **kwargs)


def library_closure(binaries, bin_dir):
    """Map soname -> file for every library that the binaries load from bin_dir."""
    env = dict(os.environ, LD_LIBRARY_PATH=str(bin_dir))
    closure = {}
    for binary in binaries:
        output = subprocess.run(["ldd", str(binary)], env=env, check=True, capture_output=True, text=True).stdout
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[1] == "=>":
                soname, path = parts[0], Path(parts[2])
                # libpython must come from the user's interpreter, never from the build. A build against a
                # conda or venv Python may not find it on the loader path, which is fine.
                if soname.startswith("libpython"):
                    continue
                if path.is_absolute() and bin_dir in path.resolve().parents:
                    closure[soname] = path.resolve()
                elif parts[2] == "not":
                    raise RuntimeError(f"{binary}: missing dependency {soname}")
    for soname in DLOPEN_LIBRARIES:
        closure[soname] = (bin_dir / soname).resolve()
    return closure


def dll_imports(binary):
    """Names of the DLLs that a PE file imports, delay-loaded ones included."""
    import pefile

    pe = pefile.PE(str(binary), fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"],
                                           pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT"]])
    names = [entry.dll.decode() for attribute in ["DIRECTORY_ENTRY_IMPORT", "DIRECTORY_ENTRY_DELAY_IMPORT"]
             for entry in getattr(pe, attribute, [])]
    pe.close()
    return names


def msvc_runtime_dir():
    """The newest Microsoft.VC*.CRT folder of Visual Studio's redistributables, else System32."""
    redist = os.environ.get("VCToolsRedistDir")
    folders = sorted(Path(redist, "x64").glob("Microsoft.VC*.CRT")) if redist else []
    return folders[-1] if folders else Path(os.environ["SystemRoot"]) / "System32"


def dll_closure(binaries, bin_dir):
    """Map lower-case name -> file for every DLL that the binaries load from bin_dir, recursively, plus the runtime-
    loaded DLLs and the MSVC runtime. Windows' own DLLs and the user's python3X.dll are left out."""
    system = Path(os.environ["SystemRoot"]) / "System32"
    crt_dir = msvc_runtime_dir()
    closure = {}
    for name in WINDOWS_DLOPEN_LIBRARIES:
        if not (bin_dir / name).exists():
            raise RuntimeError(f"{bin_dir / name} not found")
        closure[name.lower()] = bin_dir / name
    pending = list(binaries) + list(closure.values())
    seen = set(closure)
    while pending:
        binary = pending.pop()
        for name in dll_imports(binary):
            key = name.lower()
            if key in seen:
                continue
            seen.add(key)
            if re.fullmatch(r"python\d*\.dll", key):
                continue
            if MSVC_RUNTIME.match(key):
                path = crt_dir / name if (crt_dir / name).exists() else system / name
            elif (bin_dir / name).exists():
                path = bin_dir / name
            elif key.startswith(("api-ms-win-", "ext-ms-")) or (system / name).exists():
                continue
            else:
                raise RuntimeError(f"{binary}: missing dependency {name}")
            closure[key] = path
            pending.append(path)
    return closure


def needed_libraries(binary):
    output = subprocess.run(["readelf", "-d", str(binary)], check=True, capture_output=True, text=True).stdout
    return [line.split("[")[1].rstrip("]") for line in output.splitlines() if "(NEEDED)" in line]


def repair(wheel, dist_dir):
    """Turn the linux_x86_64 wheel into a manylinux wheel and delete the original."""
    command = ["auditwheel", "repair", str(wheel), "-w", str(dist_dir)]
    for library in REPAIR_EXCLUDES:
        command += ["--exclude", library]
    run(command)
    wheel.unlink()


def copy_tree(source, destination, ignore=None):
    shutil.copytree(source, destination, ignore=ignore, dirs_exist_ok=True)


def check_notices(names):
    """Warn about bundled DLLs that THIRD_PARTY_NOTICES.md does not name: their licenses must be added before a
    release."""
    notices = (HERE / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8").lower()
    missing = [name for name in names
               if name.lower() not in notices and name.lower() != CORE_LIBRARY.lower() and not MSVC_RUNTIME.match(name)]
    if missing:
        print(f"WARNING: not named in THIRD_PARTY_NOTICES.md: {' '.join(missing)}")


def stage(bin_dir, stage_dir, strip):
    package = stage_dir / PACKAGE
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    package.mkdir(parents=True)

    # Python package: our __init__.py, the extension module, and type stubs.
    shutil.copy2(HERE / PACKAGE / "__init__.py", package / "__init__.py")
    python_dir = bin_dir / "python" / "falcor"
    extension = python_dir / EXTENSION
    shutil.copy2(extension, package / extension.name)
    if (python_dir / "__init__.pyi").exists():
        shutil.copy2(python_dir / "__init__.pyi", package / "__init__.pyi")
    if (python_dir / "falcor_ext").is_dir():
        copy_tree(python_dir / "falcor_ext", package / "falcor_ext")

    # Plugins, with a plugins.json listing only the shipped ones.
    (package / "plugins").mkdir()
    plugin_files = []
    for name in PLUGINS:
        source = bin_dir / "plugins" / f"{name}{LIBRARY_SUFFIX}"
        if not source.exists():
            raise RuntimeError(f"Plugin not built: {source}")
        shutil.copy2(source, package / "plugins" / source.name)
        plugin_files.append(source)
    (package / "plugins" / "plugins.json").write_text(json.dumps(PLUGINS, indent=2) + "\n")

    if WINDOWS:
        # The D3D12 Agility SDK runtime (D3D12/) is left out: a Python module can enable it only in Windows Developer
        # Mode, so the package uses the D3D12 runtime of Windows, and Falcor skips the Agility SDK without it.
        closure = {path.name: path for path in dll_closure([extension] + plugin_files, bin_dir).values()}
    else:
        # Shared libraries under their sonames (wheels cannot contain symlinks).
        closure = library_closure([bin_dir / "libFalcor.so", extension] + plugin_files, bin_dir)
    for name, path in sorted(closure.items()):
        shutil.copy2(path, package / name)
    print(f"Bundled {len(closure)} libraries: {' '.join(sorted(closure))}")

    # Shaders: core shaders plus the shipped render passes.
    shaders = bin_dir / "shaders"

    def ignore_excluded(directory, names):
        relative = Path(directory).relative_to(shaders)
        return [name for name in names if (relative / name).as_posix() in EXCLUDED_SHADERS]

    copy_tree(shaders, package / "shaders", ignore=ignore_excluded)
    for name in RENDER_PASS_SHADERS:
        copy_tree(shaders / "RenderPasses" / name, package / "shaders" / "RenderPasses" / name)
    for name in RTXDI_WRAPPER_SHADERS:
        (package / "shaders" / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(shaders / name, package / "shaders" / name)

    # Data comes from the repository: the build's copy keeps files that were deleted from the repository.
    for name in DATA_FOLDERS:
        copy_tree(REPO / "data" / name, package / "data" / name)
    shutil.copy2(bin_dir / "settings.json", package / "settings.json")

    # Licenses.
    shutil.copy2(REPO / "LICENSE.md", package / "LICENSE.md")
    shutil.copy2(HERE / "THIRD_PARTY_NOTICES.md", package / "THIRD_PARTY_NOTICES.md")
    copy_tree(HERE / "third_party_licenses", package / "third_party_licenses")
    if WINDOWS:
        copy_tree(HERE / "third_party_licenses_windows", package / "third_party_licenses")
        check_notices(sorted(closure))
        if (package / "shaders" / "nvapi").exists():
            print("WARNING: the build has NVAPI (shaders/nvapi); add its license to THIRD_PARTY_NOTICES.md.")

    if strip and not WINDOWS:
        for library in list(package.glob("*.so*")) + list((package / "plugins").glob("*.so")):
            run(["strip", "--strip-unneeded", str(library)])
    return package


def write_setup(stage_dir, package):
    files = sorted(p.relative_to(package).as_posix() for p in package.rglob("*") if p.is_file())
    # Text files are UTF-8: Windows would otherwise use its ANSI code page (the README is not pure ASCII).
    (stage_dir / "setup.py").write_text(f'''# Generated by build_wheel.py.
from setuptools import setup
from setuptools.command.install import install
from setuptools.dist import Distribution


class BinaryDistribution(Distribution):
    """Force a platform wheel: the package ships native libraries."""

    def has_ext_modules(self):
        return True


class PlatlibInstall(install):
    """Install into platlib so the wheel is not purelib (auditwheel refuses purelib wheels)."""

    def finalize_options(self):
        super().finalize_options()
        self.install_lib = self.install_platlib


setup(
    name="{PACKAGE}",
    version="{VERSION}",
    description="GPU rendering for computational imaging, built on NVIDIA Falcor",
    long_description=open("README.md", encoding="utf-8").read(),
    long_description_content_type="text/markdown",
    license="BSD-3-Clause; bundled third-party components are under their own licenses (THIRD_PARTY_NOTICES.md)",
    author="Juhyeon Kim",
    url="https://github.com/juhyeonkim95/FalcorComp",
    project_urls={{
        "Documentation": "https://falcorcomp.readthedocs.io/",
        "Source": "https://github.com/juhyeonkim95/FalcorComp",
        "Issues": "https://github.com/juhyeonkim95/FalcorComp/issues",
    }},
    # From the official list (https://pypi.org/classifiers/): PyPI rejects unknown classifiers.
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Science/Research",
        "Environment :: GPU :: NVIDIA CUDA",
        "Operating System :: POSIX :: Linux",
        "Operating System :: Microsoft :: Windows",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Programming Language :: Python :: Implementation :: CPython",
        "Topic :: Multimedia :: Graphics :: 3D Rendering",
        "Topic :: Scientific/Engineering :: Image Processing",
        "Topic :: Scientific/Engineering :: Physics",
    ],
    packages=["{PACKAGE}"],
    package_data={{"{PACKAGE}": {files!r}}},
    # The same range in every wheel: PyPI keeps one Requires-Python per release, taken from the first
    # uploaded file. The cpXY wheel tags already select the wheel for each Python version.
    python_requires="{PYTHON_REQUIRES}",
    install_requires=["numpy"],
    distclass=BinaryDistribution,
    cmdclass={{"install": PlatlibInstall}},
    zip_safe=False,
)
''', encoding="utf-8")
    # wheel 0.37 reads license_files only from setup.cfg; it copies them into the .dist-info folder.
    (stage_dir / "setup.cfg").write_text(
        f"[metadata]\nlicense_files =\n    {PACKAGE}/LICENSE.md\n    {PACKAGE}/THIRD_PARTY_NOTICES.md\n"
    )
    shutil.copy2(HERE / "README.md", stage_dir / "README.md")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    default_build = "windows-ninja-msvc" if WINDOWS else "GCC_11.3.0x86_64-linux-gnu-nogtk"
    parser.add_argument("--build-dir", type=Path, default=REPO / "build" / default_build)
    parser.add_argument("--no-strip", action="store_true", help="keep debug symbols in the bundled libraries")
    parser.add_argument("--no-repair", action="store_true", help="keep the linux_x86_64 wheel (local use only)")
    args = parser.parse_args()

    # <build>/bin, or <build>/bin/Release for multi-config generators (the Windows presets).
    bin_dir = next((d.resolve() for d in [args.build_dir / "bin" / "Release", args.build_dir / "bin"]
                    if (d / CORE_LIBRARY).exists()), None)
    if bin_dir is None:
        raise SystemExit(f"{CORE_LIBRARY} not found in {args.build_dir / 'bin'}; build Falcor (Release) first.")
    if WINDOWS:
        try:
            import pefile  # noqa: F401
        except ImportError:
            raise SystemExit("pefile not found; run: pip install pefile")
    elif not args.no_repair:
        if any(library.startswith("libgtk") for library in needed_libraries(bin_dir / "libFalcor.so")):
            raise SystemExit("libFalcor.so links GTK; configure the build with -DFALCOR_ENABLE_GTK=OFF.")
        missing = [tool for tool in ["auditwheel", "patchelf"] if shutil.which(tool) is None]
        if missing:
            raise SystemExit(f"{' and '.join(missing)} not found; run: pip install auditwheel patchelf")
    if not (bin_dir / "python" / "falcor" / EXTENSION).exists():
        built = [p.name for p in (bin_dir / "python" / "falcor").glob("falcor_ext*")]
        raise SystemExit(f"Run this script with the Python the build used ({' '.join(built)}); this one needs "
                         f"{EXTENSION}.")

    work = args.build_dir.resolve() / PACKAGE
    stage_dir, dist_dir, raw_dir = work / "stage", work / "dist", work / "raw"
    package = stage(bin_dir, stage_dir, strip=not args.no_strip)
    write_setup(stage_dir, package)
    for directory in [dist_dir, raw_dir]:
        if directory.exists():
            shutil.rmtree(directory)
    if args.no_repair or WINDOWS:
        run([sys.executable, "setup.py", "-q", "bdist_wheel", "-d", str(dist_dir)], cwd=stage_dir)
    else:
        run([sys.executable, "setup.py", "-q", "bdist_wheel", "-d", str(raw_dir)], cwd=stage_dir)
        (wheel,) = raw_dir.glob("*.whl")
        repair(wheel, dist_dir)
    for wheel in sorted(dist_dir.glob(f"{PACKAGE}-{VERSION}-*.whl")):
        print(f"Wheel: {wheel} ({wheel.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
