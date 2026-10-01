# Sphinx configuration for the falcorcomp documentation.

project = "falcorcomp"
author = "falcorcomp developers"
copyright = "2026, falcorcomp developers"

extensions = [
    "myst_parser",
    "sphinx.ext.mathjax",
    "sphinx_design",  # tutorial cards and the Linux / Windows tabs
    "sphinx_copybutton",  # "copy" button on code blocks
]

# Leave shell and Python prompts out of the copied text; blocks without prompts are copied whole.
copybutton_prompt_text = r"\$ |>>> |\.\.\. "
copybutton_prompt_is_regexp = True
copybutton_only_copy_prompt_lines = False

myst_enable_extensions = ["colon_fence", "deflist", "dollarmath"]

source_suffix = {".md": "markdown", ".rst": "restructuredtext"}
root_doc = "index"
exclude_patterns = ["_build"]

html_theme = "furo"
html_title = "falcorcomp"
html_logo = "_static/logo_icon.png"  # the icon from ../assets/logo.png, without the text
html_static_path = ["_static"]
html_css_files = ["custom.css"]
