"""A non-iterable scalar still raises PY_TRAP_TYPE at GET_ITER."""


def managed_entry():
    result = 0
    for value in 7:
        result += value
    return result


managed_entry()
