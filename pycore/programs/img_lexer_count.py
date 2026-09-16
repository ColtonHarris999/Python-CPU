"""Token-count golden (compiler_design.md step E).

Stores source on ``_PYC_G["_in_src"]`` and runs ``_pyc_lex_main`` through
``_bi_exec_globals`` so helpers resolve in the package namespace. The host
golden is the firmware lexer's token count for this snippet (17).
"""

SRC = "def f(a, b):\n    return a + b\n"


def managed_entry():
    g = _PYC_G
    g["_in_src"] = SRC
    return _bi_exec_globals(g["_pyc_lex_main"], g)


managed_entry()
