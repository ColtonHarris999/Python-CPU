"""Kw-only None default with no positionals (CALL_KW binder path)."""


def f(*, x=None):
    if x is None:
        return 1
    return 0


def managed_entry():
    return f() * 10 + f(x=None) * 1 + f(x=2)


managed_entry()
