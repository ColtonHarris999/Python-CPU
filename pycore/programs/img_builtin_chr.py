"""BI_CHR on ASCII: one-character SHORT_STRs from code points."""


def managed_entry():
    total = 0
    if chr(65) == "A":
        total += 1
    if chr(97) == "a":
        total += 10
    if chr(48) == "0":
        total += 100
    if chr(0) == "A":
        total += 1000
    return total


managed_entry()
