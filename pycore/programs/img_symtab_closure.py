"""Closure SyntaxError golden (compiler_design.md step G).

``inner`` reads ``outer``'s local ``x``. Returns 1 when the firmware
symbol table raises ``SyntaxError``.
"""

SRC = """\
def outer():
    x = 1
    def inner():
        return x
    return inner
"""


def managed_entry():
    g = _PYC_G
    g["_in_src"] = SRC
    g["_in_mode"] = "exec"
    try:
        _bi_exec_globals(g["_pyc_symtab_main"], g)
        return 0
    except SyntaxError:
        return 1


managed_entry()
