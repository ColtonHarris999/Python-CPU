"""Positional defaults before *args; include argc==0 fill."""


def f(a=9, *rest):
    return a + 10 * len(rest)


def managed_entry():
    return f() + f(1) + f(1, 2, 3)


managed_entry()
