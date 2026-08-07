"""CO_VARARGS + two kw-only; override only the first kw-only name."""


def f(*a, x=1, y=2):
    return len(a) * 1000 + x * 100 + y


def managed_entry():
    return f(7, 8, x=3)


managed_entry()
