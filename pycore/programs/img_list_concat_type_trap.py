"""Mixed LIST+TUPLE is not sequence-concat; still PY_TRAP_TYPE (1)."""


def managed_entry():
    return [1] + (2,)


managed_entry()
