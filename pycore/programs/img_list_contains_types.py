"""CONTAINS_OP across multiple element tags on a list.

Checks INT, BOOL (True==1 cross), SHORT_STR, NONE membership.
Returns a bit-packed checksum of which memberships succeeded.
"""


def managed_entry():
    a = [7, True, "hi", None]
    n = 0
    if 7 in a:
        n = n + 1
    if 1 in a:
        # True == 1 in CPython; PyCore INT/BOOL cross-eq should match.
        n = n + 2
    if "hi" in a:
        n = n + 4
    if None in a:
        n = n + 8
    if 99 not in a:
        n = n + 16
    return n


managed_entry()
