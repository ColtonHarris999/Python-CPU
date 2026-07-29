"""Too few args even with defaults → PY_TRAP_CALL_FILTER."""


def f(a, b=5):
    return a + b


def managed_entry():
    return f()


managed_entry()
