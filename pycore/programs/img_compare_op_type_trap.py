"""Unsupported rich-comparison tags must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    value = None
    return value < 1


managed_entry()
