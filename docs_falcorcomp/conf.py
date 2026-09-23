# Sphinx configuration for the falcorcomp documentation.

project = "falcorcomp"
author = "falcorcomp developers"
copyright = "2026, falcorcomp developers"

extensions = [
    "myst_parser",
    "sphinx.ext.mathjax",
]

myst_enable_extensions = ["deflist"]

source_suffix = {".md": "markdown", ".rst": "restructuredtext"}
root_doc = "index"
exclude_patterns = ["_build"]

html_theme = "furo"
html_title = "falcorcomp"
html_static_path = ["_static"]
