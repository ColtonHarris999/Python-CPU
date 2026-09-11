"""BINARY_SLICE on LIST: interior, prefix, empty, and identity windows.

Bounds are locals so CPython emits BINARY_SLICE (and BUILD_LIST rather than
LIST_EXTEND of a const tuple). Host golden: 1+20+200+0 = 221.
"""


def managed_entry():
    one = 1
    two = 2
    three = 3
    four = 4
    zero = 0
    xs = [one, two, three, four]
    a = xs[zero:two]
    b = xs[one:three]
    empty = xs[two:two]
    total = a[0] + 10 * a[1]
    total += 100 * b[0]
    if len(empty) == 0:
        total += 0
    return total


managed_entry()
