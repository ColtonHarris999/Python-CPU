"""Nested TUPLE dict key still PY_TRAP_TYPE (1)."""


def managed_entry():
    d = {}
    d[(1, (2, 3))] = 1
    return 0


managed_entry()
