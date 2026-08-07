"""CO_VARARGS: no excess positionals produces an empty *a tuple."""


def f(*a):
    return len(a)


def managed_entry():
    return f()


managed_entry()
