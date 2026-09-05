"""int() of a non-convertible tag must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    return int(None)


managed_entry()
