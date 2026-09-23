#!/usr/bin/env python3
"""Build the falcorcomp wheel from an existing Falcor build (Linux).

The package directory becomes Falcor's runtime directory: Falcor resolves
plugins/, shaders/, data/ and settings.json relative to libFalcor.so, and the
built binaries already use $ORIGIN runpaths, so no relinking is needed.

    python3 packaging/falcorcomp/build_wheel.py [--build-dir build/GCC_11.3.0x86_64-linux-gnu]

The wheel is written to <build-dir>/falcorcomp/dist/.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

VERSION = "0.1.0"
PACKAGE = "falcorcomp"
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

# Render passes and scene importers shipped in the package.
PLUGINS = [
    # ToF render passes.
    "TimeGatedPathTracerInline",
    "TimeGatedReSTIRInline",
    "TransientHistogramPathTracerInline",
    # Passes used by ToF render graphs (VBufferRT/LaserVBufferRT, accumulation, tone mapping).
    "GBuffer",
    "AccumulatePass",
    "ToneMapper",
    # Scene importers (.pbrt, .pyscene, .xml, and meshes via Assimp).
    "PBRTImporter",
    "PythonImporter",
    "MitsubaImporter",
    "AssimpImporter",
]
# Shader folders under shaders/RenderPasses for the plugins above (and what they import).
RENDER_PASS_SHADERS = [
    "TimeGatedPathTracerInline", "TimeGatedReSTIRInline", "TransientHistogramPathTracerInline",
    "Shared", "GBuffer", "AccumulatePass", "ToneMapper",
]
# Core shader folders that are only used by tests and samples.
EXCLUDED_CORE_SHADERS = {"RenderPasses", "Samples", "Tests", "Testing"}
DATA_FOLDERS = ["framework", "bluenoise"]
# Libraries loaded with dlopen() at runtime, which ldd cannot see.
DLOPEN_LIBRARIES = ["libslang-glslang.so", "libtbbmalloc.so.2"]


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
                if path.is_absolute() and bin_dir in path.resolve().parents:
                    closure[soname] = path.resolve()
                elif parts[2] == "not":
                    raise RuntimeError(f"{binary}: missing dependency {soname}")
    for soname in DLOPEN_LIBRARIES:
        closure[soname] = (bin_dir / soname).resolve()
    # libpython must come from the user's interpreter, never from the build.
    return {s: p for s, p in closure.items() if not s.startswith("libpython")}


def copy_tree(source, destination, ignore=None):
    shutil.copytree(source, destination, ignore=ignore, dirs_exist_ok=True)


def stage(bin_dir, stage_dir, strip):
    package = stage_dir / PACKAGE
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    package.mkdir(parents=True)

    # Python package: our __init__.py, the extension module, and type stubs.
    shutil.copy2(HERE / PACKAGE / "__init__.py", package / "__init__.py")
    python_dir = bin_dir / "python" / "falcor"
    extensions = sorted(python_dir.glob("falcor_ext.cpython-*.so"))
    if len(extensions) != 1:
        raise RuntimeError(f"Expected one falcor_ext extension in {python_dir}, found {extensions}")
    extension = extensions[0]
    shutil.copy2(extension, package / extension.name)
    if (python_dir / "__init__.pyi").exists():
        shutil.copy2(python_dir / "__init__.pyi", package / "__init__.pyi")
    if (python_dir / "falcor_ext").is_dir():
        copy_tree(python_dir / "falcor_ext", package / "falcor_ext")

    # Plugins, with a plugins.json listing only the shipped ones.
    (package / "plugins").mkdir()
    plugin_files = []
    for name in PLUGINS:
        source = bin_dir / "plugins" / f"{name}.so"
        if not source.exists():
            raise RuntimeError(f"Plugin not built: {source}")
        shutil.copy2(source, package / "plugins" / source.name)
        plugin_files.append(source)
    (package / "plugins" / "plugins.json").write_text(json.dumps(PLUGINS, indent=2) + "\n")

    # Shared libraries under their sonames (wheels cannot contain symlinks).
    closure = library_closure([bin_dir / "libFalcor.so", extension] + plugin_files, bin_dir)
    for soname, path in sorted(closure.items()):
        shutil.copy2(path, package / soname)
    print(f"Bundled {len(closure)} libraries: {' '.join(sorted(closure))}")

    # Shaders: all core shaders plus the shipped render passes.
    shaders = bin_dir / "shaders"
    for entry in shaders.iterdir():
        if entry.name in EXCLUDED_CORE_SHADERS:
            continue
        if entry.is_dir():
            copy_tree(entry, package / "shaders" / entry.name)
        else:
            shutil.copy2(entry, package / "shaders" / entry.name)
    for name in RENDER_PASS_SHADERS:
        copy_tree(shaders / "RenderPasses" / name, package / "shaders" / "RenderPasses" / name)

    for name in DATA_FOLDERS:
        copy_tree(bin_dir / "data" / name, package / "data" / name)
    shutil.copy2(bin_dir / "settings.json", package / "settings.json")

    # Licenses.
    shutil.copy2(REPO / "LICENSE.md", package / "LICENSE.md")
    if (bin_dir / "pythondist" / "PACKAGE-LICENSES").is_dir():
        copy_tree(bin_dir / "pythondist" / "PACKAGE-LICENSES", package / "third_party_licenses" / "python")

    if strip:
        for library in list(package.glob("*.so*")) + list((package / "plugins").glob("*.so")):
            run(["strip", "--strip-unneeded", str(library)])
    return package


def write_setup(stage_dir, package):
    files = sorted(str(p.relative_to(package)) for p in package.rglob("*") if p.is_file())
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
    description="Falcor with time-of-flight rendering (ToF ReSTIR)",
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    license="BSD-3-Clause",
    packages=["{PACKAGE}"],
    package_data={{"{PACKAGE}": {files!r}}},
    python_requires="=={sys.version_info[0]}.{sys.version_info[1]}.*",
    install_requires=["numpy"],
    distclass=BinaryDistribution,
    cmdclass={{"install": PlatlibInstall}},
    zip_safe=False,
)
''')
    shutil.copy2(HERE / "README.md", stage_dir / "README.md")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--build-dir", type=Path, default=REPO / "build" / "GCC_11.3.0x86_64-linux-gnu")
    parser.add_argument("--no-strip", action="store_true", help="keep debug symbols in the bundled libraries")
    args = parser.parse_args()

    bin_dir = (args.build_dir / "bin").resolve()
    if not (bin_dir / "libFalcor.so").exists():
        raise SystemExit(f"libFalcor.so not found in {bin_dir}; build Falcor first.")
    extension_tag = next((bin_dir / "python" / "falcor").glob("falcor_ext.cpython-*.so")).name.split(".")[1]
    running_tag = f"cpython-{sys.version_info[0]}{sys.version_info[1]}-x86_64-linux-gnu"
    if extension_tag != running_tag:
        raise SystemExit(f"Run this script with the Python the build used ({extension_tag}), not {running_tag}.")

    work = args.build_dir.resolve() / PACKAGE
    stage_dir, dist_dir = work / "stage", work / "dist"
    package = stage(bin_dir, stage_dir, strip=not args.no_strip)
    write_setup(stage_dir, package)
    dist_dir.mkdir(parents=True, exist_ok=True)
    run([sys.executable, "setup.py", "-q", "bdist_wheel", "-d", str(dist_dir)], cwd=stage_dir)
    for wheel in sorted(dist_dir.glob(f"{PACKAGE}-{VERSION}-*.whl")):
        print(f"Wheel: {wheel} ({wheel.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
