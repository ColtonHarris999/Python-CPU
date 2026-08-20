"""An unhandled raise is fatal: PY_TRAP_RAISE (17).

The exception-table walk finds no handler, so the machine halts rather than
silently continuing.
"""


def managed_entry():
    raise SyntaxError


managed_entry()
