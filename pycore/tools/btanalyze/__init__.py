"""Retargetable, read-only CPython 3.14 bytecode analyzer for PyCore.

The package reports two things for a hardware stack-machine target:

* fold candidates -- contiguous instruction runs a fold unit could fuse, and
* hardware-friendly gaps -- opcodes the target cannot (yet) execute well.

All hardware behavior is described by an external target file (see
``pycore/targets/pycore.json``); nothing about PyCore is hard-coded here.
"""

from __future__ import annotations

__all__ = ["targets", "cfg", "folds", "gaps", "report", "corpus"]
