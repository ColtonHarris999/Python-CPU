"""Image-boot parity coverage for BOOL range arguments."""


def managed_entry():
    count = 0
    for value in range(True):
        count += value + 1
    for value in range(False, True, True):
        count += value + 1
    return count


managed_entry()
