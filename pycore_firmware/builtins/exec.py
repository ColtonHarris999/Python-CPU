"""Execute a precompiled code object for its side effects; returns None.

``exec(code)`` calls the object in the current globals (module-scope
``STORE_NAME`` / ``LOAD_NAME``). ``exec(code, globals)`` switches the
callee's ``globals_base_r`` to the supplied dict via ``_bi_exec_globals``
and restores the caller's globals on return (Plan 1 P4).

A distinct ``locals=`` mapping is deferred (Plan 2); a third positional
argument is a CALL_FILTER trap because this body only takes two formals.

The string form (``exec("x = 1")``) needs runtime ``compile()`` and is Plan 2;
see ``planning/native_compiler_plan.md`` §8.1.

Host note: CPython code objects are not callable, so ``run_image_test.py``
overrides this body with a stand-in bound to the test program's globals. The
device runs this source.
"""


def exec(code, globals=None):
    if globals is None:
        code()
    else:
        _bi_exec_globals(code, globals)
    return None
