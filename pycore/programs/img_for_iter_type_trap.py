"""GET_ITER on an unsupported scalar must raise PY_TRAP_TYPE (1)."""


def managed_entry():
    total = 0
    for value in 7:
        total += value
    return total


managed_entry()
