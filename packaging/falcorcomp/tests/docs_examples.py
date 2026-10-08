"""Runs every Python example of the docs' plugin reference pages against the installed falcorcomp wheel, each in its
own process: a testbed with the tutorials' scenes folder as working directory, the example, two frames. Reports
exceptions and "Unknown property" warnings. Blocks without a render graph only show syntax and are skipped.

    python packaging/falcorcomp/tests/docs_examples.py [--device d3d12|vulkan] [<page.md> ...]
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parents[3] / "docs_falcorcomp/src"
SCENES = DOCS / "tutorials/scenes"
PRELUDE = '''
import falcorcomp as falcor
falcor.Logger.verbosity = falcor.Logger.Level.Warning
testbed = falcor.Testbed(create_window=False, device_type=falcor.DeviceType.{device})
'''
EPILOGUE = '''
if testbed.scene is None:
    testbed.load_scene("cornell-box/scene-v4-nolight.pbrt", falcor.SceneBuilderFlags.DontMergeMaterials)
testbed.resize_frame_buffer(128, 128)
testbed.frame()
testbed.frame()
print("EXAMPLE_OK")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pages", nargs="*", type=Path, help="pages to run (default: all of plugin_reference)")
    parser.add_argument("--device", choices=["default", "d3d12", "vulkan"], default="default")
    args = parser.parse_args()
    device = {"default": "Default", "d3d12": "D3D12", "vulkan": "Vulkan"}[args.device]
    pages = [p.resolve() for p in args.pages] or sorted((DOCS / "plugin_reference").rglob("*.md"))
    failed = 0
    for page in pages:
        blocks = re.findall(r"```python\n(.*?)```", page.read_text(encoding="utf-8"), re.S)
        for i, block in enumerate(blocks):
            if "create_render_graph" not in block and not block.lstrip().startswith("# The same graph"):
                continue
            # The FMCW variant continues the block before it.
            previous = blocks[i - 1] if block.lstrip().startswith("# The same graph") else ""
            testbed = f"falcor.Testbed(device_type=falcor.DeviceType.{device}, "
            example = (previous + block).replace("falcor.Testbed(", testbed)
            # Window examples (the transient viewer) run headless: no window, no interactive loop.
            example = example.replace("create_window=True", "create_window=False").replace("testbed.run()", "")
            code = PRELUDE.format(device=device) + example + EPILOGUE
            result = subprocess.run([sys.executable, "-c", code], cwd=SCENES, capture_output=True, text=True,
                                    errors="replace", timeout=900)
            out = result.stdout + result.stderr
            unknown = sorted(set(re.findall(r"Unknown property '([^']+)' in (\w+)", out)))
            ok = "EXAMPLE_OK" in out and result.returncode == 0 and not unknown
            failed += not ok
            print(f"{page.relative_to(DOCS).as_posix()} block {i + 1}: {'OK' if ok else 'FAILED'}"
                  f"{' unknown ' + str(unknown) if unknown else ''}", flush=True)
            if not ok:
                # Errors and Falcor's fatal message, without the shader compiler's warnings.
                errors = [line for line in out.splitlines()
                          if any(key in line for key in ["(Error)", "(Fatal)", "Error:", "error"])]
                for line in (errors or out.strip().splitlines()[-3:])[:8]:
                    print(f"    {line[:300]}", flush=True)
    print(f"{'ALL EXAMPLES OK' if not failed else f'{failed} EXAMPLE(S) FAILED'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
