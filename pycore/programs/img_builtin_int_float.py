"""CALL seeded int() on FLOAT — truncate toward zero (CPython int(float))."""


def managed_entry():
    total = 0
    if int(3.7) == 3:
        total += 1
    if int(-2.9) == -2:
        total += 10
    if int(0.5) == 0:
        total += 100
    if int(-0.5) == 0:
        total += 1000
    if int(1.0) == 1:
        total += 10000
    if int(4.0 / 2) == 2:
        total += 100000
    return total


managed_entry()
