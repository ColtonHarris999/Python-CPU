"""UNPACK_EX starred rest (G9 row 11).

The source list is built once so BUILD_LIST does not steal the run-end abort.
Each iteration only allocates the rest list.
"""


def managed_entry():
    a = 1
    b = 2
    c = 3
    d = 4
    src = [a, b, c, d]
    total = 0
    keep = [0]
    for i in range(800):
        x, *rest = src
        keep = rest
        total = total + x + rest[0] + rest[1] + len(rest) + i % 2
    return total + keep[1]


managed_entry()
