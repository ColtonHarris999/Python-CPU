"""Locals-vs-globals checksum golden (compiler_design.md step G).

Module name ``x`` is global; ``f``'s locals are ``a``, ``b``, ``y``.
Stores source and ``exec`` mode on ``_PYC_G`` and runs ``_pyc_symtab_main``.
"""

SRC = """\
x = 1
def f(a, b):
    y = a + b
    return y + x
"""


def managed_entry():
    g = _PYC_G
    g["_in_src"] = SRC
    g["_in_mode"] = "exec"
    return _bi_exec_globals(g["_pyc_symtab_main"], g)


managed_entry()
