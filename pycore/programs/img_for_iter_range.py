"""Image-boot parity coverage for native range(stop) iteration."""


def managed_entry():
    total = 0
    for value in range(5):
        total += value
    return total


managed_entry()
