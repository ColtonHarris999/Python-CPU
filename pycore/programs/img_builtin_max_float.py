"""CALL BI_MAX with FLOAT / mixed INT — original winning entry, first on tie."""


def managed_entry():
    total = 0
    if max(3.5, 0) == 3.5:
        total += 1
    if max(0, 1.5) == 1.5:
        total += 10
    if max(5, 1.5) == 5:
        total += 100
    if max(-1.5, 0) == 0:
        total += 1000
    if max(3, 7) == 7:
        total += 10000
    if max(0.0, 0) == 0.0:
        total += 100000
    return total


managed_entry()
