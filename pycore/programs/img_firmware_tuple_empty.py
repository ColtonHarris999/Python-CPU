"""ROM tuple() with no args must return empty (None-default CALL fill).

Host golden: 103.
"""


def managed_entry():
    t = tuple()
    total = 0
    if len(t) == 0:
        total += 100
    u = tuple([1, 2])
    total += u[0] + u[1]
    return total


managed_entry()
