"""Positional + keyword for the same formal with **kwargs → CALL_FILTER.

CPython: TypeError multiple values for argument. Leftover packing must not
swallow the duplicate.
"""


def f(a, **k):
    return a + len(k)


def managed_entry():
    return f(1, a=2)


managed_entry()
