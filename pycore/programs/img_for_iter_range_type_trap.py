"""range() rejects unsupported argument tags with PY_TRAP_TYPE (1)."""


def managed_entry():
    total = 0
    for value in range(1.5):
        total += value
    return total


managed_entry()
