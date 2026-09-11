"""Native list.pop empty → catch IndexError. Expected: 9."""


def managed_entry():
    try:
        [].pop()
    except IndexError:
        return 9
    return 0


managed_entry()
