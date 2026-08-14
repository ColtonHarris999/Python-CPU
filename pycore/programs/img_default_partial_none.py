"""Trailing None default with one required positional (non-wipe path)."""


def f(a, b=None):
    if b is None:
        return a + 10
    return a + b


def managed_entry():
    return f(1) + f(1, None) + f(1, 2)


managed_entry()
