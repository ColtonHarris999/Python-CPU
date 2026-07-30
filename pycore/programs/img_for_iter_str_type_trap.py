"""GET_ITER on a non-iterable scalar raises PY_TRAP_TYPE."""


def managed_entry():
    total = 0
    for value in 7:
        total += value
    return total


managed_entry()
