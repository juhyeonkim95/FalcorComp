"""Build, package and smoke-test the Windows falcorcomp wheels: one Falcor build per Python version.

Needs Visual Studio 2022 with "Desktop development with C++" (MSVC v143, Windows SDK 10.0.19041 or newer), git, and
conda (Anaconda or Miniconda): run it from a prompt where conda works, such as the Anaconda Prompt, with any Python:

    python packaging/falcorcomp/build_windows_wheels.py [--versions 3.12] [--skip-build] [--skip-smoke]

It runs setup.bat (submodules and packman dependencies) once, then for each Python version X.Y:
1. creates the conda environment falcorcomp-pyXY (python=X.Y) if it does not exist and installs the packaging tools;
2. configures build/windows-ninja-msvc-pyXY with -DFALCOR_USE_SYSTEM_PYTHON=ON and that Python, and builds the
   targets that the wheel ships (Release);
3. packages the wheel with build_wheel.py and copies it to build/falcorcomp-wheels;
4. installs it into a fresh venv, build/falcorcomp-smoke-pyXY, and runs tests/smoke_test.py.
Each step logs to build/falcorcomp-wheels/<step>-pyXY.log. The MSVC environment (vcvars64.bat) is set up from
Visual Studio's installation unless cl.exe is already on PATH.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from build_wheel import PACKAGE, PLUGINS, VERSION

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CMAKE = REPO / "tools" / ".packman" / "cmake" / "bin" / "cmake.exe"
PRESET = "windows-ninja-msvc"
VERSIONS = ["3.9", "3.10", "3.11", "3.12", "3.13"]
OUT = REPO / "build" / "falcorcomp-wheels"


def read_log(log):
    return log.read_text(encoding="utf-8", errors="replace").splitlines()


def run(command, log, **kwargs):
    """Runs a command with its output in log; on failure, prints the end of the log and exits."""
    command = [str(c) for c in command]
    print(f"  > {' '.join(command)}", flush=True)
    with open(log, "a", encoding="utf-8") as f:
        f.write(f"> {' '.join(command)}\n")
        f.flush()
        result = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, **kwargs)
    if result.returncode != 0:
        tail = "\n".join(read_log(log)[-40:])
        raise SystemExit(f"{tail}\nFAILED (exit code {result.returncode}); full log: {log}")


def msvc_environment():
    """The environment of an x64 Visual Studio developer prompt."""
    if shutil.which("cl"):
        return dict(os.environ)
    vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    install = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires",
                              "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
                             capture_output=True, text=True, check=True).stdout.strip()
    if not install:
        raise SystemExit("Visual Studio with the C++ tools (MSVC x64) was not found.")
    vcvars = Path(install) / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    output = subprocess.run(f'call "{vcvars}" >nul && set', shell=True, capture_output=True, text=True,
                            check=True).stdout
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def conda_python(conda, version, log):
    """The python.exe of the conda environment falcorcomp-pyXY, created if missing."""
    name = f"falcorcomp-py{version.replace('.', '')}"
    envs = json.loads(subprocess.run([conda, "info", "--json"], capture_output=True, text=True, check=True).stdout)
    prefix = next((Path(p) for p in envs["envs"] if Path(p).name == name), None)
    if prefix is None:
        run([conda, "create", "-y", "-n", name, f"python={version}"], log)
        envs = json.loads(subprocess.run([conda, "info", "--json"], capture_output=True, text=True, check=True).stdout)
        prefix = next(Path(p) for p in envs["envs"] if Path(p).name == name)
    return prefix / "python.exe"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--versions", nargs="+", default=VERSIONS, choices=VERSIONS, help="Python versions")
    parser.add_argument("--skip-build", action="store_true", help="package and test existing builds")
    parser.add_argument("--skip-smoke", action="store_true", help="do not install and test the wheels")
    args = parser.parse_args()
    if sys.platform != "win32":
        raise SystemExit("This script builds the Windows wheels; on Linux, see build_wheel.py.")
    conda = os.environ.get("CONDA_EXE") or shutil.which("conda")
    if conda is None:
        raise SystemExit("conda not found; run this from the Anaconda Prompt.")

    OUT.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        print("setup.bat", flush=True)
        subprocess.run(["cmd", "/c", str(REPO / "setup.bat")], cwd=REPO, check=True)
    # Also for packaging: build_wheel.py takes the MSVC runtime from the redistributables folder (VCToolsRedistDir).
    msvc = msvc_environment()
    results = {}
    for version in args.versions:
        tag = version.replace(".", "")
        build_dir = REPO / "build" / f"{PRESET}-py{tag}"
        logs = {step: OUT / f"{step}-py{tag}.log" for step in ["env", "build", "package", "smoke"]}
        for log in logs.values():
            log.unlink(missing_ok=True)
        print(f"== Python {version}: {build_dir}", flush=True)
        python = conda_python(conda, version, logs["env"])
        run([python, "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel", "pefile"], logs["env"])
        if not args.skip_build:
            run([CMAKE, "--preset", PRESET, "-B", build_dir, "-DFALCOR_USE_SYSTEM_PYTHON=ON",
                 f"-DPython_EXECUTABLE={python}"], logs["build"], cwd=REPO, env=msvc)
            run([CMAKE, "--build", build_dir, "--config", "Release", "--target", "FalcorPython", *PLUGINS],
                logs["build"], cwd=REPO, env=msvc)
        run([python, HERE / "build_wheel.py", "--build-dir", build_dir], logs["package"], cwd=REPO, env=msvc)
        (wheel,) = (build_dir / PACKAGE / "dist").glob(f"{PACKAGE}-{VERSION}-*.whl")
        shutil.copy2(wheel, OUT / wheel.name)
        for line in read_log(logs["package"]):
            if "WARNING" in line:
                print(f"  {line}")
        results[version] = wheel.name
        if not args.skip_smoke:
            venv = REPO / "build" / f"falcorcomp-smoke-py{tag}"
            run([python, "-m", "venv", "--clear", venv], logs["smoke"])
            venv_python = venv / "Scripts" / "python.exe"
            run([venv_python, "-m", "pip", "install", OUT / wheel.name], logs["smoke"])
            # The installed package, outside the repository; the build's bin folder is not on PATH.
            run([venv_python, HERE / "tests" / "smoke_test.py", REPO / "docs_falcorcomp/src/tutorials/scenes"],
                logs["smoke"], cwd=venv)
            results[version] += ": " + next(line for line in reversed(read_log(logs["smoke"])) if "SMOKE" in line)
    print("\nWheels in", OUT)
    for version, result in results.items():
        print(f"  {version}: {result}")


if __name__ == "__main__":
    main()
