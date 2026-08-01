"""RAISE_VARARGS oparg=1 → fatal PY_TRAP_RAISE (17)."""


def managed_entry():
    e = 1
    raise e


managed_entry()
