# Shared output setting for experiment shell scripts.
OUTPUT_PATH="$(python3 "$(dirname -- "${BASH_SOURCE[0]}")/output_config.py")"
export OUTPUT_PATH
