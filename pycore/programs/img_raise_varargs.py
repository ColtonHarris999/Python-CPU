"""RAISE_VARARGS oparg=1 of a non-exception int → PY_TRAP_TYPE (1)."""


def managed_entry():
    e = 1
    raise e


managed_entry()
