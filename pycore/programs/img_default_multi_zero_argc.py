"""Multiple positional defaults with zero supplied args."""


def f(a=1, b=2, c=3):
    return a * 100 + b * 10 + c


def managed_entry():
    return f() + f(9) + f(9, 8)


managed_entry()
