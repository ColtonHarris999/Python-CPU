"""Locate the vendored PyCPython tree.

PyCPython is a git submodule at ``vendor/pycpython``. Firmware never imports
it on the hart; host tests and image tooling use it as a ``compile()`` oracle.
See ``planning/compile_plan.md``.
"""

from __future__ import annotations

import pathlib
import sys

VENDOR_PYCPYTHON = pathlib.Path(__file__).resolve().parents[2] / "vendor" / "pycpython"


def ensure_importable() -> pathlib.Path:
    """Put the submodule root on ``sys.path`` and return it.

    Raises ``FileNotFoundError`` if the submodule was not initialized
    (``git submodule update --init``).
    """
    if not (VENDOR_PYCPYTHON / "pycpython" / "compile.py").is_file():
        raise FileNotFoundError(
            f"PyCPython submodule missing at {VENDOR_PYCPYTHON}. "
            "Run: git submodule update --init --recursive"
        )
    root = str(VENDOR_PYCPYTHON)
    if root not in sys.path:
        sys.path.insert(0, root)
    return VENDOR_PYCPYTHON
