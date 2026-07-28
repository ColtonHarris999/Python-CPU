"""CONTAINS_OP on a dict (key probe; miss is False, not KeyError)."""


def managed_entry():
    d = {}
    d["x"] = 2
    d[3] = 9
    n = 0
    if "x" in d:
        n = n + 1
    if 3 in d:
        n = n + 2
    if "y" not in d:
        n = n + 4
    if 99 not in d:
        n = n + 8
    return n


managed_entry()
