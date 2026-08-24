"""Construct and catch a TypeError carrying one positional argument."""


def managed_entry():
    try:
        raise TypeError("x")
    except TypeError:
        return 21


managed_entry()
