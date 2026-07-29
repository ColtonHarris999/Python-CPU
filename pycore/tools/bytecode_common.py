#!/usr/bin/env python3
"""Shared CPython 3.14 bytecode helpers for PyCore host tools.

These helpers are factored out of ``preprocess.py`` so that the bytecode
analyzer (``analyze_bytecode.py``) and the preprocessor agree on how a source
function is loaded and how a constant is tagged. ``preprocess.py`` re-exports
the names it historically owned, so nothing downstream of it changes.
"""

from __future__ import annotations

import importlib.util
import pathlib
import struct
import sys


REQUIRED_PY = (3, 14)

TAG_UNINITIALIZED = 0b000
TAG_INT = 0b001
TAG_FLOAT = 0b010
TAG_BOOL = 0b011
TAG_PTR = 0b100
TAG_OBJECT = 0b101

TAG_NAMES = {
    TAG_UNINITIALIZED: "UNINITIALIZED",
    TAG_INT: "INT",
    TAG_FLOAT: "FLOAT",
    TAG_BOOL: "BOOL",
    TAG_PTR: "PTR",
    TAG_OBJECT: "OBJECT",
}

# Architectural value is a 128-bit field carrying a 3-bit tag. INT keeps a
# 64-bit signed fast path sign-extended into the upper bits; FLOAT/BOOL live in
# the low 64 bits with the rest zero.
VAL_WIDTH = 128
VAL_MASK = (1 << VAL_WIDTH) - 1


def require_python_3_14() -> None:
    if sys.version_info[:2] != REQUIRED_PY:
        raise RuntimeError(
            "PyCore tooling is pinned to CPython "
            f"{REQUIRED_PY[0]}.{REQUIRED_PY[1]}; running "
            f"{sys.version_info.major}.{sys.version_info.minor}"
        )


def load_function(source: pathlib.Path, function_name: str):
    spec = importlib.util.spec_from_file_location("_pycore_input", source)
    if spec is None or spec.loader is None:
        raise ValueError(f"Unable to import {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fn = getattr(module, function_name, None)
    if not callable(fn):
        raise ValueError(f"Function '{function_name}' not found in {source}")
    return fn


def float_bits(value: float) -> int:
    return struct.unpack(">Q", struct.pack(">d", value))[0]


def tag_constant(value: object) -> tuple[int, int]:
    if isinstance(value, bool):
        return TAG_BOOL, int(value)
    if isinstance(value, int):
        # Two's-complement masked to 128 bits sign-extends negatives correctly.
        return TAG_INT, value & VAL_MASK
    if isinstance(value, float):
        return TAG_FLOAT, float_bits(value)
    return TAG_OBJECT, 0
