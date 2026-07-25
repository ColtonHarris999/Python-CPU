"""Simple CONTAINS_OP on a list: in and not in.

Returns 1 if (2 in a) and (9 not in a), else 0.
"""


def managed_entry():
    x0 = 1
    x1 = 2
    x2 = 3
    a = [x0, x1, x2]
    ok_in = 2 in a
    ok_out = 9 not in a
    if ok_in:
        if ok_out:
            return 1
        return 0
    return 0


managed_entry()
