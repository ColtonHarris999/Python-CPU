"""STR * INT is not sequence-repeat; still PY_TRAP_TYPE (1)."""


def managed_entry():
    return "ab" * 3


managed_entry()
