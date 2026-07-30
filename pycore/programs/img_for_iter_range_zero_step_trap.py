"""range() rejects a zero step with PY_TRAP_TYPE (1)."""


def managed_entry():
    total = 0
    for value in range(0, 5, 0):
        total += value
    return total


managed_entry()
