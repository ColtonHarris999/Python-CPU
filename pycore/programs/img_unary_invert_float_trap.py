"""FLOAT + UNARY_INVERT must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    z = 1.5
    return ~z


managed_entry()
