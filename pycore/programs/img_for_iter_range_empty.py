"""Image-boot parity coverage for immediately exhausted ranges."""


def managed_entry():
    total = 0
    for value in range(0):
        total += value
    for value in range(3, 3):
        total += value
    return total


managed_entry()
