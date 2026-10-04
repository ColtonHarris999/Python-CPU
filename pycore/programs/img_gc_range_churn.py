"""CALL range wide (G9 row 25): mode-1 96 B 3-tuple, never iterated."""


def managed_entry():
    total = 0
    keep = None
    for i in range(800):
        keep = range(0, 1099511627776, 7)
        total = total + i
    return total + (0 if keep is None else 1)


managed_entry()
