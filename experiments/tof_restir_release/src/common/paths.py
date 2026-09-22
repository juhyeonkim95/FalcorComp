"""Output locations shared with the experiment shell scripts."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from output_config import OUTPUT_PATH

RELEASE_OUTPUT_PATH = OUTPUT_PATH.expanduser().resolve()
