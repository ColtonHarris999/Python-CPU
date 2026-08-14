"""except ValueError: does not catch raise TypeError → PY_TRAP_RAISE (17)."""


def managed_entry():
    try:
        raise TypeError
    except ValueError:
        return 1


managed_entry()
