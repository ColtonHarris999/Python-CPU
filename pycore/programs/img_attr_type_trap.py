"""LOAD_ATTR on a non-OBJECT receiver → PY_TRAP_TYPE (1)."""


def managed_entry():
    x = 1
    return x.foo


managed_entry()
