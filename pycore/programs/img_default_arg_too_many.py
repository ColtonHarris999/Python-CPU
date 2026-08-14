"""Too many positionals with defaults present → CALL_FILTER (trap 6)."""


def f(a, b=5):
    return a + b


def managed_entry():
    return f(1, 2, 3)


managed_entry()
