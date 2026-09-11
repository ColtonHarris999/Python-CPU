"""Negative LIST slice bounds do not wrap: PY_TRAP_TYPE (1)."""


def managed_entry():
    one = 1
    xs = [one, one]
    return len(xs[one:-one])


managed_entry()
