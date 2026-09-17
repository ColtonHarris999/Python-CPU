"""Closure freevar golden (compiler_design.md §11.4).

``inner`` reads ``outer``'s local ``x``. Returns 1 when the firmware
symbol table records ``x`` as a freevar of ``inner``.
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
    _bi_exec_globals(g["_pyc_symtab_main"], g)
    i = 0
    found = 0
    while i < g["sc_n"]:
        if (g["sc_kind"][i] & 255) == 1:
            nid = g["sc_node"][i]
            if g["nd_obj"][nid] == "inner":
                n_free = g["sc_kind"][i] >> 8
                nloc = g["sc_nlocals"][i]
                names = g["sc_varnames"][i]
                if n_free >= 1:
                    if names[nloc - 1] == "x":
                        found = 1
        i = i + 1
    return found


managed_entry()
