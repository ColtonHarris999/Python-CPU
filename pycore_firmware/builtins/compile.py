"""Compile source into a code object for eval / exec.

Public ROM shim (compiler_design.md §4.2 / step I). Helpers live in
``_PYC_G``; this body stores ``_in_src`` / ``_in_file`` / ``_in_mode``
and runs ``_pyc_codegen_main`` under ``_bi_exec_globals``.

``_PYC_ENTRY`` stays the step-D toy trampoline (``img_pyc_package_call``
→ 42). Re-entrancy (``_busy``) is deferred: the static dict is already
at 127 of 128 keys (D9).
"""


def compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1):
    if flags != 0:
        raise ValueError("compile(): flags must be 0")
    if optimize != -1 and optimize != 0:
        raise ValueError("compile(): invalid optimize value")
    if mode != "exec" and mode != "eval":
        raise ValueError("compile() mode must be 'exec' or 'eval'")
    g = _PYC_G
    g["_in_src"] = source
    g["_in_file"] = filename
    g["_in_mode"] = mode
    return _bi_exec_globals(g["_pyc_codegen_main"], g)
