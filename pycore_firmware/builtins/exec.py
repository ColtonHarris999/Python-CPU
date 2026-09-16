"""Execute a string or precompiled code object; returns None.

``exec(code)`` calls the object in the current globals (module-scope
``STORE_NAME`` / ``LOAD_NAME``). ``exec(code, globals)`` switches the
callee's ``globals_base_r`` to the supplied dict via ``_bi_exec_globals``
and restores the caller's globals on return.

A distinct ``locals=`` mapping is deferred; a third positional argument is
a CALL_FILTER trap because this body only takes two formals.

String form (``exec("x = 1")``) probes the argument tag with
``_bi_code_kind`` and, for SHORT_STR (7) / LONG_STR (8), runs
``compile(source, "<string>", "exec")`` then the resulting code object.
Non-string / non-code still TYPE- or CALL_FILTER-traps on ``code()``.

Host note: CPython code objects are not callable, so ``run_image_test.py``
overrides this body with a stand-in bound to the test program's globals. The
device runs this source.
"""


def exec(code, globals=None):
    k = _bi_code_kind(code)
    if k == 7:
        code = compile(code, "<string>", "exec")
    if k == 8:
        code = compile(code, "<string>", "exec")
    if globals is None:
        code()
    else:
        _bi_exec_globals(code, globals)
    return None
