"""Firmware pow() raises catchable ValueError for a negative modular exponent."""


def managed_entry():
    try:
        pow(2, -1, 5)
    except ValueError:
        return 43
    return 0


managed_entry()
