"""CALL the seeded int type: identity, bool, decimal SHORT_STR, argc 0."""


def managed_entry():
    total = 0
    if int() == 0:
        total += 1
    if int(7) == 7:
        total += 10
    if int(True) == 1:
        total += 100
    if int(False) == 0:
        total += 1000
    if int("42") == 42:
        total += 10000
    if int("-8") == -8:
        total += 100000
    if int("+9") == 9:
        total += 1000000
    return total


managed_entry()
