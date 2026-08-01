"""Empty strings exhaust on the first FOR_ITER."""


def managed_entry():
    total = 0
    for c in "":
        total += 1
    return total


managed_entry()
