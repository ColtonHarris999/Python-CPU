"""T1 assemble+call golden (compiler_design.md step H).

Stores source and ``eval`` mode on ``_PYC_G``, runs ``_pyc_codegen_main``,
and calls the assembled code object. Host and device goldens are 3 (A1
early, without the ``compile()`` shim).
"""

SRC = "1 + 2"


def managed_entry():
    g = _PYC_G
    g["_in_src"] = SRC
    g["_in_mode"] = "eval"
    co = _bi_exec_globals(g["_pyc_codegen_main"], g)
    return co()


managed_entry()
