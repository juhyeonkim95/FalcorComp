"""Single output-root setting for release experiments. Edit OUTPUT_PATH here."""

from pathlib import Path

OUTPUT_PATH = Path("/media/juhyeon/Data2/FalcorCompOutputs/tof_restir_release")

if __name__ == "__main__":
    print(OUTPUT_PATH.expanduser().resolve())
