"""Evaluate a precompiled expression code object and return its value.

An ``"eval"``-mode code object ends in ``RETURN_VALUE`` of the expression, so
calling it yields the value directly. ``eval(code, globals)`` uses the same
``_bi_exec_globals`` switch as ``exec`` (Plan 1 P4).

See ``exec.py`` for the host stand-in note. The string form is Plan 2
(``planning/native_compiler_plan.md`` §8.1).
"""


def eval(code, globals=None):
    if globals is None:
        return code()
    return _bi_exec_globals(code, globals)
