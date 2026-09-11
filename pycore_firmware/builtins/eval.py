"""Evaluate a precompiled expression code object and return its value.

An ``"eval"``-mode code object ends in ``RETURN_VALUE`` of the expression, so
calling it yields the value directly. ``eval(code, globals)`` uses the same
``_bi_exec_globals`` switch as ``exec``.

See ``exec.py`` for the host stand-in note. The string form waits on
ROM ``compile()`` (``planning/compile_plan.md``).
"""


def eval(code, globals=None):
    if globals is None:
        return code()
    return _bi_exec_globals(code, globals)
