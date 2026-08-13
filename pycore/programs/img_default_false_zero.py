"""All-defaults False / 0 survive argc==0 frame init."""


def f(a=False):
    if a is False:
        return 1
    return 0


def g(a=0):
    return a + 7


def managed_entry():
    return f() + g() + g(3)


managed_entry()
