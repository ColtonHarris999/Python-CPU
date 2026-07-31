"""Deleting a key during DICT iteration trips the version guard."""


def managed_entry():
    d = {1: 2, 3: 4}
    result = 0
    for key in d:
        result += key
        del d[3]
    return result


managed_entry()
