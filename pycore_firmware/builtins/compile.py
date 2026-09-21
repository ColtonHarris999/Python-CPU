"""Compile source into a code object for eval / exec.

Public ROM shim (compiler_design.md §4.2 / step I). Helpers live in
``_PYC_G``; this body stores ``_in_src`` / ``_in_file`` / ``_in_mode``
and runs ``_pyc_codegen_main`` under ``_bi_exec_globals``.

``_PYC_ENTRY`` stays the step-D toy trampoline (``img_pyc_package_call``
→ 42). Nested ``if`` and bare ``raise ValueError`` keep the ROM body on
the raise-type path (no ``CALL`` to construct).

``_in_src`` / ``_in_file`` / ``_in_mode`` and every compiler arena are
module state on ``_PYC_G``, so a ``compile()`` entered while another is
still on the stack would overwrite the outer call's source mid-parse.
``_busy`` makes that a clean ``ValueError`` (D9). No path reaches it
today -- ``exec(compile(src))`` is sequential, and the compiler never
calls ``compile`` -- so the guard is there for the day one appears.
``finally`` clears it, or a ``SyntaxError`` would poison the next call.
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
    if g["_busy"]:
        raise ValueError
    g["_busy"] = 1
    try:
        g["_in_src"] = source
        g["_in_file"] = filename
        g["_in_mode"] = mode
        return _bi_exec_globals(g["_pyc_codegen_main"], g)
    finally:
        g["_busy"] = 0
