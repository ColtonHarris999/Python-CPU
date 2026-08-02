"""CALL_KW: positional+keyword and keyword-only reorder on CODE_OBJECT."""


def g(a, b=0, c=0):
    return a + 10 * b + 100 * c


def t5(a, b=0, *, c=1):
    return a + 10 * b + 100 * c


def managed_entry():
    x = g(1, b=2)
    y = g(b=2, a=1)
    z = g(1, c=3)
    w = t5(10, c=3)
    return x + y + z + w


managed_entry()
