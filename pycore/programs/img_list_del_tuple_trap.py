"""DELETE_SUBSCR on a tuple → PY_TRAP_TYPE (trap code 1)."""


def managed_entry():
    t = (1, 2, 3)
    del t[0]
    return 0


managed_entry()
