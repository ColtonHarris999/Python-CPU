"""ord() of a non-string must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    return ord(5)


managed_entry()
