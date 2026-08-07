"""CO_VARARGS: excess positional arguments are packed into *a."""


def f(*a):
    return len(a)


def managed_entry():
    return f(1, 2, 3)


managed_entry()
