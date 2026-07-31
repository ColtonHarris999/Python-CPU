"""Image-boot parity coverage for a positive range step."""


def managed_entry():
    total = 0
    for value in range(2, 10, 3):
        total += value
    return total


managed_entry()
