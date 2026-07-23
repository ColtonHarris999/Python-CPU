"""Cross-tag CONTAINS_OP via DICT_COLLISION (True / 1).

Requires EXCORE_EN=1. Bitmask: 1 in d, True in d, 0 not in d.
"""


def managed_entry():
    d = {}
    d[True] = 9
    n = 0
    if 1 in d:
        n = n + 1
    if True in d:
        n = n + 2
    if 0 not in d:
        n = n + 4
    return n


managed_entry()
