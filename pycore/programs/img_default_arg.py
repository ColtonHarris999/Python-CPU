"""Defaults folded at image-build time via SET_FUNCTION_ATTRIBUTE."""


def f(a, b=5):
    return a + b


def managed_entry():
    return f(1) + f(1, 2)


managed_entry()
