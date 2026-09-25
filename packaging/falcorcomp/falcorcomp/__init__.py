"""falcorcomp: Falcor with time-of-flight render passes.

Usage mirrors the ``falcor`` module of a Falcor build:

    import falcorcomp as falcor
    testbed = falcor.Testbed(create_window=False)

The package directory is Falcor's runtime directory: libFalcor.so, its libraries,
``plugins/``, ``shaders/`` and ``data/`` all live next to this file.
"""
import ctypes as _ctypes
import os as _os
import sys as _sys
import sysconfig as _sysconfig

__version__ = "0.1.3"


def _preload_libpython():
    """libFalcor.so links libpython (it embeds an interpreter for scripting).

    Interpreters in conda environments or venvs often do not expose libpython on
    the loader path, so load it by full path before importing the extension.
    Once a library with that soname is loaded, the dynamic linker reuses it.
    """
    soname = "libpython{}.{}.so.1.0".format(*_sys.version_info[:2])
    libdir = _sysconfig.get_config_var("LIBDIR") or ""
    candidates = [_os.path.join(libdir, soname), soname]
    ldlibrary = _sysconfig.get_config_var("LDLIBRARY")
    if ldlibrary:
        candidates.insert(1, _os.path.join(libdir, ldlibrary))
    for candidate in candidates:
        try:
            _ctypes.CDLL(candidate, mode=_ctypes.RTLD_GLOBAL)
            return
        except OSError:
            continue
    raise ImportError(
        f"falcorcomp needs {soname}, which was not found. Install the shared Python "
        f"library (e.g. 'apt install libpython{_sys.version_info[0]}.{_sys.version_info[1]}') "
        "or use a Python distribution that ships it (e.g. conda)."
    )


def _default_shader_cache_path():
    """Per-user cache: Falcor's default, next to libFalcor.so, may not be writable after pip install."""
    cache_home = _os.environ.get("XDG_CACHE_HOME") or _os.path.join(_os.path.expanduser("~"), ".cache")
    return _os.path.join(cache_home, "falcorcomp", __version__, "shadercache")


if _os.environ.get("FALCOR_DEVMODE") == "1":
    # Development mode would read shaders from the original source tree.
    del _os.environ["FALCOR_DEVMODE"]

# Read by Falcor when a device is created; set it yourself to move the cache, or to "" to disable it.
_os.environ.setdefault("FALCOR_SHADER_CACHE_PATH", _default_shader_cache_path())

_preload_libpython()

from .falcor_ext import *  # noqa: E402,F401,F403
from . import falcor_ext as _falcor_ext  # noqa: E402

# Falcor's C++ runs "from falcor import *" for render-graph scripts and .pyscene
# files, so this package must also be importable as "falcor".
_sys.modules.setdefault("falcor", _sys.modules[__name__])

del _ctypes, _sysconfig
