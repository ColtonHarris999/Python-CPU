"""GET_ITER on a runtime BUILD_TUPLE (not a folded constant).

Expected result: 4 + 5 = 9.
"""


def managed_entry():
    p, q = 4, 5
    total = 0
    for x in (p, q):
        total += x
    return total


managed_entry()
