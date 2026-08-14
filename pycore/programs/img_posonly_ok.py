"""Positional-only without **kwargs: positionals bind; other kwargs trap not needed.

f(1, b=2) is valid when only `a` is positional-only.
"""


def f(a, /, b=0):
    return a + 10 * b


def managed_entry():
    return f(1) + f(2, b=3) + f(4, 5)


managed_entry()
