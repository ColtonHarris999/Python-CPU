"""Evaluate a precompiled expression code object and return its value.

An ``"eval"``-mode code object ends in ``RETURN_VALUE`` of the expression, so
calling it yields the value directly. ``eval(code, globals)`` uses the same
``_bi_exec_globals`` switch as ``exec``.

See ``exec.py`` for the host stand-in note. The string form is
``eval(compile(...))`` (ROM ``compile()``, step I); auto str dispatch
waits on ``_bi_code_kind``.
"""


def eval(code, globals=None):
    if globals is None:
        return code()
    return _bi_exec_globals(code, globals)
