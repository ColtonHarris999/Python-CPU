"""str() of an unsupported tag must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    return str([])


managed_entry()
