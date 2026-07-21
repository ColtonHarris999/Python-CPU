"""Robust mix: locals, STORE_SUBSCR, DELETE_SUBSCR, CONTAINS_OP, calls.

Exercises delete/contains alongside existing container + CALL support.
"""


def helper(xs):
    # Delete last, then check membership of a removed and remaining value.
    del xs[2]
    if 30 not in xs:
        if 10 in xs:
            return xs[0] + xs[1]
        return 0
    return 0


def managed_entry():
    xs = [10, 20, 30]
    xs[1] = 25
    # [10, 25, 30]
    s = helper(xs)
    # helper deleted 30 → [10, 25]; returns 35
    if 25 in xs:
        return s + xs[0]
    return 0


managed_entry()
