"""GET_ITER on a list that existed before a caught exception (G8 seed 0).

A list allocated before `try`/`except`, then iterated after the handler,
TYPE-traps on the device. A list built after the handler iterates correctly.
"""


class Box:
    def __init__(self, kind, val):
        self.kind = kind
        self.val = val


def managed_entry():
    acc = 0
    a = Box(0, 0)
    b = Box(1, "ab")
    c = Box(7, None)
    before = [a, b, c]
    try:
        raise KeyError
    except KeyError:
        acc = acc + 3
    for e in before:
        acc = acc + e.kind
    after_a = Box(0, 0)
    after_b = Box(1, "cd")
    after_c = Box(7, None)
    after = [after_a, after_b, after_c]
    for e in after:
        acc = acc + e.kind
    return acc


managed_entry()
