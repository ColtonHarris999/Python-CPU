"""Image-boot parity coverage for range(start, stop) and range(stop)."""


def managed_entry():
    total = 0
    for value in range(1, 4):
        total += value
    for value in range(10):
        total += value
    return total


managed_entry()
