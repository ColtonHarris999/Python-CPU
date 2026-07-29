"""UNPACK_SEQUENCE length mismatch must raise PY_TRAP_TYPE (trap 1)."""


def managed_entry():
    t = (1,)
    a, b = t
    return a


managed_entry()
