"""SET_UPDATE with a duplicate element (A1).

Two-core used to hang or drop the element. CPython's set has one 1.
"""


def managed_entry():
    xs = [1, 2, 2, 3, 4]
    t = {*xs}
    n = 0
    if 1 in t:
        n = n + 1
    if 2 in t:
        n = n + 1
    if 3 in t:
        n = n + 1
    if 4 in t:
        n = n + 1
    return n


managed_entry()
