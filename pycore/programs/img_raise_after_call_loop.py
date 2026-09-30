"""RAISE in a frame after a call returned: handler depth uses this frame's nlocals.

The hart places the handler stack at locals_base + nlocals + depth. A normal
RETURN left nlocals at the callee's count, so a raise after calling a
function with more locals unwound too high and the loop's FOR_ITER ran on
garbage (TYPE trap). Expected result: 6.
"""


def wide(a, b, c, d, e, f, g):
    return a


def managed_entry():
    t = 0
    for i in [1, 2, 3]:
        wide(1, 2, 3, 4, 5, 6, 7)
        try:
            raise ValueError("x")
        except ValueError:
            t += i
    return t


managed_entry()
