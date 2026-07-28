"""Rebinding the source name does not change the iterator's source object.

The loop still yields 1, 2, 3 from the original list; xs names [9, 9]
after the first iteration. Expected result: 6 + 9 = 15.
"""


def managed_entry():
    a, b, c = 1, 2, 3
    xs = [a, b, c]
    total = 0
    for x in xs:
        total += x
        if x == 1:
            y = 9
            xs = [y, y]
    return total + xs[0]


managed_entry()
