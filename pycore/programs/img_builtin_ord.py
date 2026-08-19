"""BI_ORD on ASCII: code points from one-character SHORT_STRs."""


def managed_entry():
    total = 0
    if ord("A") == 65:
        total += 1
    if ord("a") == 97:
        total += 10
    if ord("0") == 48:
        total += 100
    if ord(" ") == 32:
        total += 1000
    return total


managed_entry()
