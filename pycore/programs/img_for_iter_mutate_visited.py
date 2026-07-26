"""Rewrite an already-visited list element during iteration.

The yielded values remain 1, 2, 3 while storage at index 0 becomes 9.
Expected result: (1 + 2 + 3) + 10 * 9 = 96.
"""


def managed_entry():
    a, b, c = 1, 2, 3
    xs = [a, b, c]
    total = 0
    for x in xs:
        total += x
        if x == 2:
            xs[0] = 9
    return total + 10 * xs[0]


managed_entry()
