"""set() builds an empty SET that exhausts immediately."""


def managed_entry():
    result = 7
    for value in set():
        result += value
    return result


managed_entry()
