"""Image-boot coverage for native SHORT_STR iteration."""


def managed_entry():
    total = 0
    for c in "123":
        total += 1
    return total


managed_entry()
