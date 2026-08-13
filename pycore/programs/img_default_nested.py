"""Nested all-default calls (outer and inner both argc==0)."""


def inner(y=4):
    return y


def outer(x=3):
    return x + inner()


def managed_entry():
    return outer() + outer(10)


managed_entry()
