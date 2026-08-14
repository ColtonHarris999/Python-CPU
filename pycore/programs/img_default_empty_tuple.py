"""Empty-tuple positional default filled when argc==0."""


def f(a=()):
    return len(a) + 3


def managed_entry():
    return f() + f((1, 2))


managed_entry()
