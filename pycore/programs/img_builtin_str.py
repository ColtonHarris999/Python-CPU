"""CALL the seeded str type: identity, int, bool, None, argc 0."""


def managed_entry():
    total = 0
    if str() == "":
        total += 1
    if str("hi") == "hi":
        total += 10
    if str(42) == "42":
        total += 100
    if str(True) == "True":
        total += 1000
    if str(False) == "False":
        total += 10000
    if str(None) == "None":
        total += 100000
    if str(-8) == "-8":
        total += 1000000
    return total


managed_entry()
