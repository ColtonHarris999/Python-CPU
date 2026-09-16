"""Evaluate a string or precompiled expression code object.

An ``"eval"``-mode code object ends in ``RETURN_VALUE`` of the expression, so
calling it yields the value directly. ``eval(code, globals)`` uses the same
``_bi_exec_globals`` switch as ``exec``.

String form (``eval("1 + 2")``) probes the argument tag with
``_bi_code_kind`` and, for SHORT_STR (7) / LONG_STR (8), runs
``compile(source, "<string>", "eval")`` then the resulting code object.

See ``exec.py`` for the host stand-in note.
"""


def eval(code, globals=None):
    k = _bi_code_kind(code)
    if k == 7:
        code = compile(code, "<string>", "eval")
    if k == 8:
        code = compile(code, "<string>", "eval")
    if globals is None:
        return code()
    return _bi_exec_globals(code, globals)
