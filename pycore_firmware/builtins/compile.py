"""Compile source into a code object for eval / exec.

Public ROM shim (compiler_design.md §4.2 / step I). Helpers live in
``_PYC_G``; this body stores ``_in_src`` / ``_in_file`` / ``_in_mode``
and runs ``_pyc_codegen_main`` under ``_bi_exec_globals``.

``_PYC_ENTRY`` stays the step-D toy trampoline (``img_pyc_package_call``
→ 42). Re-entrancy (``_busy``) is deferred (D9): a flag set before the
call and cleared after is worse than none, because an ordinary
``SyntaxError`` would leave it set and poison every later ``compile()``.
It needs ``try`` / ``finally`` here. Nested ``if`` and bare ``raise
ValueError`` keep the ROM body on the raise-type path (no ``CALL`` to
construct).
"""


def compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1):
    if flags:
        raise ValueError
    if optimize != -1:
        if optimize != 0:
            raise ValueError
    ok = 0
    if mode == "eval":
        ok = 1
    if mode == "exec":
        ok = 1
    if ok == 0:
        raise ValueError
    g = _PYC_G
    g["_in_src"] = source
    g["_in_file"] = filename
    g["_in_mode"] = mode
    return _bi_exec_globals(g["_pyc_codegen_main"], g)
