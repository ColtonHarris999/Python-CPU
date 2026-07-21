"""CONTAINS_OP across multiple element tags on a list.

Checks INT, BOOL (True==1 cross), SHORT_STR, NONE membership.
Returns a bit-packed checksum of which memberships succeeded.
"""


def managed_entry():
    i = 7
    t = True
    s = "hi"
    none_v = None
    a = [i, t, s, none_v]
    acc = 0
    if 7 in a:
        acc = acc + 1
    if 1 in a:
        # True == 1 in CPython; PyCore INT/BOOL cross-eq should match.
        acc = acc + 2
    if "hi" in a:
        acc = acc + 4
    if None in a:
        acc = acc + 8
    if 99 not in a:
        acc = acc + 16
    return acc


managed_entry()
