"""Positional-only without **kwargs: keyword for / param → CALL_FILTER."""


def f(a, /):
    return a


def managed_entry():
    return f(a=1)


managed_entry()
