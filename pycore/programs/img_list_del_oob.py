"""DELETE_SUBSCR OOB → PY_TRAP_MEM_FAULT (trap code 7)."""


def managed_entry():
    a = [1, 2]
    del a[5]
    return 0


managed_entry()
