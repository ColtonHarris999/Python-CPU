"""Missing method on a list → PY_TRAP_ATTR_ERROR (15)."""


def managed_entry():
    xs = []
    return xs.foo


managed_entry()
