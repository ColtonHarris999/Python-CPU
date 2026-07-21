"""DELETE_SUBSCR OOB → PY_TRAP_MEM_FAULT (trap code 7)."""


def managed_entry():
    x0 = 1
    x1 = 2
    a = [x0, x1]
    del a[5]
    return 0


managed_entry()
