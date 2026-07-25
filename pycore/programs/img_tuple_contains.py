"""CONTAINS_OP on a tuple."""


def managed_entry():
    t = (10, 20, 30)
    if 20 in t:
        if 99 not in t:
            return 42
        return 0
    return 0


managed_entry()
