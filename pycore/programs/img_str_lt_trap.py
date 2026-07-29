"""String ordering via COMPARE_OP must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    a = "a"
    b = "b"
    return a < b


managed_entry()
