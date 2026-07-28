"""Shrinking the current list to empty makes the next FOR_ITER exhaust.

The first element is yielded, then three deletes emulate clear() without
LOAD_ATTR. Expected sum: 1.
"""


def managed_entry():
    a, b, c = 1, 2, 3
    xs = [a, b, c]
    total = 0
    for x in xs:
        total += x
        if x == 1:
            del xs[2]
            del xs[1]
            del xs[0]
    return total


managed_entry()
