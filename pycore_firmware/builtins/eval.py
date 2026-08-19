"""Evaluate a precompiled expression code object and return its value.

An ``"eval"``-mode code object ends in ``RETURN_VALUE`` of the expression, so
calling it yields the value directly. See ``exec.py`` for why this needs no new
hardware, and for the host stand-in note.

The string form is Plan 2 (``planning/native_compiler_plan.md`` §8.1).
"""


def eval(code):
    return code()
